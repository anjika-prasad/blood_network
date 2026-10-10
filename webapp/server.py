"""
Blood Network Console - local web front end for the blood inventory schema.

Runs on the machine that hosts the Oracle database and listens on 127.0.0.1 only,
so nothing outside this computer can reach it.

    pip install -r requirements.txt
    python server.py

Credentials are read from ORA_USER / ORA_PWD / ORA_DSN (same variables as
07_concurrency_test.py). Anything missing is asked for at start-up; the password
is never written to disk.
"""
import datetime
import getpass
import os
import re
import threading
import webbrowser
from contextlib import contextmanager

import oracledb
from flask import Flask, abort, jsonify, request
from werkzeug.exceptions import HTTPException

HOST = "127.0.0.1"                       # loopback only - do not change to 0.0.0.0
PORT = int(os.environ.get("PORT", "5000"))
LOCAL_ADDRS = {"127.0.0.1", "::1"}
LOCAL_HOSTS = {"127.0.0.1", "localhost"}

USER = PWD = None
DSN = os.environ.get("ORA_DSN", "localhost/XEPDB1")

app = Flask(__name__, static_folder="static", static_url_path="")


# ---------- plumbing ---------------------------------------------------
@contextmanager
def db():
    """One connection = one transaction per HTTP request (commit on success)."""
    conn = oracledb.connect(user=USER, password=PWD, dsn=DSN)
    try:
        yield conn.cursor()
        conn.commit()
    except BaseException:
        conn.rollback()
        raise
    finally:
        conn.close()


def rows(cur, sql, **binds):
    cur.execute(sql, binds)
    cols = [c[0].lower() for c in cur.description]
    return [{k: (v.isoformat() if isinstance(v, datetime.date) else v) for k, v in zip(cols, r)}
            for r in cur]


def body():
    data = request.get_json(silent=True)      # JSON only: blocks cross-site form posts
    if not isinstance(data, dict):
        abort(400, "Expected a JSON body")
    return data


def num(data, key, label, lo=None, hi=None):
    try:
        v = int(data.get(key))
    except (TypeError, ValueError):
        abort(400, f"{label} is required")
    if (lo is not None and v < lo) or (hi is not None and v > hi):
        abort(400, f"{label} must be between {lo} and {hi}")
    return v


def text(data, key, label, max_len):
    v = str(data.get(key) or "").strip()
    if not v:
        abort(400, f"{label} is required")
    if len(v) > max_len:
        abort(400, f"{label} must be at most {max_len} characters")
    return v


@app.before_request
def local_only():
    if request.remote_addr not in LOCAL_ADDRS or request.host.split(":")[0] not in LOCAL_HOSTS:
        abort(403, "This console only answers requests from this computer")


@app.errorhandler(HTTPException)
def http_error(e):
    return jsonify(error=e.description), e.code


@app.errorhandler(oracledb.Error)
def db_error(e):
    first = str(e).splitlines()[0]
    m = re.match(r"ORA-(\d{5}): (.*)", first)
    code, msg = (int(m[1]), m[2]) if m else (0, first)
    if 20000 <= code <= 20999:               # RAISE_APPLICATION_ERROR from the triggers/procedures
        return jsonify(error=msg), 400
    if code == 1:
        return jsonify(error="That record already exists (duplicate value)"), 400
    if code == 1403:
        return jsonify(error="No such record"), 404
    return jsonify(error=first), 500


@app.get("/")
def index():
    return app.send_static_file("index.html")


# ---------- reference data + dashboard ---------------------------------
@app.get("/api/meta")
def meta():
    with db() as cur:
        return jsonify(
            user=USER, dsn=DSN,
            hospitals=rows(cur, """SELECT hospital_id, hospital_name, city FROM hospital
                                   WHERE is_active = 'Y' ORDER BY hospital_id"""),
            groups=rows(cur, "SELECT group_id, group_name FROM blood_group ORDER BY group_id"))


@app.get("/api/dashboard")
def dashboard():
    with db() as cur:
        stats = rows(cur, """
            SELECT (SELECT COUNT(*) FROM blood_unit
                    WHERE status IN ('AVAILABLE','NEAR_EXPIRY') AND expiry_date > SYSDATE) AS usable_units,
                   (SELECT COUNT(*) FROM v_expiring_soon)                                   AS expiring_soon,
                   (SELECT COUNT(*) FROM patient_request
                    WHERE status IN ('PENDING','PARTIAL','TRANSFER_PENDING'))               AS open_requests,
                   (SELECT COUNT(*) FROM blood_transfer WHERE status = 'IN_TRANSIT')        AS in_transit
            FROM dual""")[0]
        return jsonify(
            stats=stats,
            stock=rows(cur, """SELECT hospital_id, hospital_name, group_name, usable_units, open_demand,
                                      min_level, max_level, stock_flag
                               FROM v_shortage_surplus ORDER BY hospital_id"""),
            network=rows(cur, "SELECT * FROM v_network_summary"),
            expiring=rows(cur, """SELECT * FROM v_expiring_soon
                                  ORDER BY days_to_expiry FETCH FIRST 10 ROWS ONLY"""),
            wastage=rows(cur, "SELECT * FROM v_wastage_report ORDER BY hospital_name"))


# ---------- inventory --------------------------------------------------
@app.get("/api/units")
def units():
    a = request.args
    with db() as cur:
        return jsonify(rows(cur, """
            SELECT * FROM v_unit_detail
            WHERE  (:h IS NULL OR hospital_id = :h)
            AND    (:g IS NULL OR group_id = :g)
            AND    (:s IS NULL OR status = :s)
            ORDER  BY expiry_date, unit_id
            FETCH FIRST 500 ROWS ONLY""",
            h=a.get("hospital_id", type=int), g=a.get("group_id", type=int), s=a.get("status") or None))


@app.get("/api/units/<int:unit_id>")
def unit(unit_id):
    with db() as cur:
        found = rows(cur, """
            SELECT v.*, u.volume_ml, d.full_name AS donor_name
            FROM   v_unit_detail v
                   JOIN blood_unit u ON u.unit_id  = v.unit_id
                   JOIN donor d      ON d.donor_id = u.donor_id
            WHERE  v.unit_id = :id""", id=unit_id)
        if not found:
            abort(404, f"Unit {unit_id} does not exist")
        return jsonify(
            unit=found[0],
            history=rows(cur, """SELECT old_status, new_status, changed_at FROM unit_status_log
                                 WHERE unit_id = :id ORDER BY log_id""", id=unit_id),
            allocation=rows(cur, """SELECT a.request_id, r.patient_ref, a.allocated_at
                                    FROM request_allocation a
                                         JOIN patient_request r ON r.request_id = a.request_id
                                    WHERE a.unit_id = :id""", id=unit_id))


# ---------- donors -----------------------------------------------------
@app.get("/api/donors")
def donors():
    with db() as cur:
        return jsonify(rows(cur, """
            SELECT d.donor_id, d.full_name, d.date_of_birth, d.gender, d.phone, g.group_name,
                   d.last_donation_date,
                   (SELECT COUNT(*) FROM blood_unit u WHERE u.donor_id = d.donor_id) AS units_donated
            FROM   donor d JOIN blood_group g ON g.group_id = d.group_id
            ORDER  BY d.donor_id DESC
            FETCH FIRST 1000 ROWS ONLY"""))


@app.post("/api/donors")
def add_donor():
    d = body()
    try:
        dob = datetime.date.fromisoformat(str(d.get("date_of_birth")))
    except ValueError:
        abort(400, "Date of birth is required")
    if d.get("gender") not in ("M", "F", "O"):
        abort(400, "Gender is required")
    with db() as cur:
        new_id = cur.var(int)
        cur.execute("""INSERT INTO donor (full_name, date_of_birth, gender, phone, group_id)
                       VALUES (:n, :dob, :g, :p, :gid) RETURNING donor_id INTO :id""",
                    n=text(d, "full_name", "Name", 100), dob=dob, g=d["gender"],
                    p=text(d, "phone", "Phone", 15), gid=num(d, "group_id", "Blood group"), id=new_id)
        return jsonify(donor_id=new_id.getvalue()[0])


@app.post("/api/donations")
def add_donation():
    d = body()
    with db() as cur:
        unit_id = cur.var(int)
        cur.callproc("record_donation", [num(d, "donor_id", "Donor"), num(d, "hospital_id", "Hospital"),
                                         num(d, "volume_ml", "Volume", 200, 500), unit_id])
        return jsonify(unit_id=unit_id.getvalue())


# ---------- requests + allocation --------------------------------------
REQUEST_SQL = """
    SELECT f.request_id, r.patient_ref, f.hospital_name, f.group_name, f.units_required, f.urgency,
           f.status, f.request_time, f.fulfilled_at, f.minutes_to_fulfil,
           (SELECT COUNT(*) FROM request_allocation a WHERE a.request_id = f.request_id) AS allocated,
           (SELECT COUNT(*) FROM blood_transfer t
            WHERE t.request_id = f.request_id AND t.status = 'IN_TRANSIT')              AS in_transit
    FROM   v_request_fulfilment f JOIN patient_request r ON r.request_id = f.request_id
"""


@app.get("/api/requests")
def requests_list():
    with db() as cur:
        return jsonify(rows(cur, REQUEST_SQL + " ORDER BY f.request_id DESC FETCH FIRST 500 ROWS ONLY"))


@app.post("/api/requests")
def add_request():
    d = body()
    if d.get("urgency") not in ("CRITICAL", "URGENT", "ROUTINE"):
        abort(400, "Urgency is required")
    with db() as cur:
        new_id = cur.var(int)
        cur.execute("""INSERT INTO patient_request (hospital_id, patient_ref, group_id, units_required, urgency)
                       VALUES (:h, :p, :g, :n, :u) RETURNING request_id INTO :id""",
                    h=num(d, "hospital_id", "Hospital"), p=text(d, "patient_ref", "Patient reference", 30),
                    g=num(d, "group_id", "Blood group"), n=num(d, "units_required", "Units", 1, 99),
                    u=d["urgency"], id=new_id)
        rid = new_id.getvalue()[0]
        if d.get("allocate"):
            cur.callproc("allocate_request", [rid])
        return jsonify(rows(cur, REQUEST_SQL + " WHERE f.request_id = :id", id=rid)[0])


@app.post("/api/requests/<int:rid>/allocate")
def allocate(rid):
    with db() as cur:
        cur.callproc("allocate_request", [rid])
        return jsonify(rows(cur, REQUEST_SQL + " WHERE f.request_id = :id", id=rid)[0])


# ---------- transfers --------------------------------------------------
@app.get("/api/transfers")
def transfers():
    with db() as cur:
        return jsonify(rows(cur, """
            SELECT t.transfer_id, t.unit_id, g.group_name, hf.hospital_name AS from_hospital,
                   ht.hospital_name AS to_hospital, t.request_id, t.initiated_at, t.received_at, t.status
            FROM   blood_transfer t
                   JOIN hospital hf   ON hf.hospital_id = t.from_hospital_id
                   JOIN hospital ht   ON ht.hospital_id = t.to_hospital_id
                   JOIN blood_unit u  ON u.unit_id      = t.unit_id
                   JOIN donor d       ON d.donor_id     = u.donor_id
                   JOIN blood_group g ON g.group_id     = d.group_id
            ORDER  BY CASE t.status WHEN 'IN_TRANSIT' THEN 0 ELSE 1 END, t.transfer_id DESC
            FETCH FIRST 500 ROWS ONLY"""))


@app.post("/api/transfers")
def add_transfer():
    d = body()
    with db() as cur:
        cur.callproc("initiate_transfer", [num(d, "unit_id", "Unit"), num(d, "to_hospital_id", "Destination")])
        return jsonify(ok=True)


@app.post("/api/transfers/<int:tid>/receive")
def receive(tid):
    with db() as cur:
        cur.callproc("receive_transfer", [tid])
        return jsonify(rows(cur, "SELECT status FROM blood_transfer WHERE transfer_id = :id", id=tid)[0])


# ---------- expiry sweep + audit ---------------------------------------
@app.post("/api/sweep")
def sweep():
    with db() as cur:
        cur.callproc("sweep_expiry")
        return jsonify(rows(cur, """SELECT flagged_near_expiry, marked_expired FROM expiry_sweep_log
                                    ORDER BY sweep_id DESC FETCH FIRST 1 ROWS ONLY""")[0])


@app.get("/api/activity")
def activity():
    with db() as cur:
        return jsonify(
            sweeps=rows(cur, """SELECT * FROM expiry_sweep_log
                                ORDER BY sweep_id DESC FETCH FIRST 15 ROWS ONLY"""),
            changes=rows(cur, """SELECT * FROM unit_status_log
                                 ORDER BY log_id DESC FETCH FIRST 60 ROWS ONLY"""))


if __name__ == "__main__":
    USER = os.environ.get("ORA_USER") or input("Oracle username: ").strip()
    PWD = os.environ.get("ORA_PWD") or getpass.getpass("Oracle password: ")
    try:
        with db() as c:
            c.execute("SELECT COUNT(*) FROM blood_group")
    except oracledb.Error as e:
        raise SystemExit(f"\nCould not use the database at {DSN} as {USER}:\n  {str(e).splitlines()[0]}\n"
                         "Check ORA_DSN and that 01-05 have been run in this schema.")
    url = f"http://{HOST}:{PORT}"
    print(f"\nBlood Network Console running at {url}  (this computer only)\nPress Ctrl+C to stop.\n")
    threading.Timer(1.0, webbrowser.open, [url]).start()
    app.run(host=HOST, port=PORT, debug=False)
