"""
07_concurrency_test.py - real multi-session stress test.

25 patients (1 unit of O+ each) hit hospital 4 at the same instant, 25 separate DB
connections. Expected: no unit is issued twice, no deadlock/error, and exactly
min(25, usable O+ units) requests are served.

    pip install oracledb
    set ORA_USER=...  ORA_PWD=...  ORA_DSN=localhost/XEPDB1     (Windows)
    export ORA_USER=... ORA_PWD=... ORA_DSN=localhost/XEPDB1     (Linux/Mac)
    python 07_concurrency_test.py
"""
import os
import threading
import oracledb

USER, PWD = os.environ["ORA_USER"], os.environ["ORA_PWD"]
DSN = os.environ.get("ORA_DSN", "localhost/XEPDB1")
HOSPITAL, GROUP, N_UNITS, N_REQ = 4, "O+", 20, 25


def connect():
    return oracledb.connect(user=USER, password=PWD, dsn=DSN)


def setup(cur):
    cur.execute("SELECT group_id FROM blood_group WHERE group_name = :g", g=GROUP)
    gid = cur.fetchone()[0]
    cur.execute("""SELECT MIN(donor_id) FROM donor WHERE group_id = :g""", g=gid)
    donor = cur.fetchone()[0]
    for _ in range(N_UNITS):
        cur.execute("""INSERT INTO blood_unit (donor_id, hospital_id, collection_date)
                       VALUES (:d, :h, TRUNC(SYSDATE) - 10)""", d=donor, h=HOSPITAL)
    req_ids = []
    for i in range(N_REQ):
        rid = cur.var(int)
        cur.execute("""INSERT INTO patient_request (hospital_id, patient_ref, group_id, units_required)
                       VALUES (:h, :p, :g, 1) RETURNING request_id INTO :r""",
                    h=HOSPITAL, p=f"CONC-{i}", g=gid, r=rid)
        req_ids.append(rid.getvalue()[0])
    # usable O+ (or compatible) units at the hospital, incl. any left over from earlier tests
    cur.execute("""SELECT COUNT(*) FROM blood_unit u JOIN donor d ON d.donor_id = u.donor_id
                   JOIN blood_compatibility bc ON bc.donor_group_id = d.group_id AND bc.recipient_group_id = :g
                   WHERE u.hospital_id = :h AND u.status IN ('AVAILABLE','NEAR_EXPIRY') AND u.expiry_date > SYSDATE""",
                g=gid, h=HOSPITAL)
    usable = cur.fetchone()[0]
    return req_ids, usable


def worker(rid, barrier, errors):
    try:
        conn = connect()
        cur = conn.cursor()
        barrier.wait()                               # all threads fire together
        cur.callproc("allocate_request", [rid, "N", "FEFO"])
        conn.commit()
        conn.close()
    except Exception as e:                           # noqa
        errors.append((rid, str(e)))


if __name__ == "__main__":
    conn = connect()
    cur = conn.cursor()
    req_ids, usable = setup(cur)
    conn.commit()
    print(f"{N_REQ} concurrent requests vs {usable} usable compatible units")

    barrier, errors = threading.Barrier(N_REQ), []
    threads = [threading.Thread(target=worker, args=(r, barrier, errors)) for r in req_ids]
    [t.start() for t in threads]
    [t.join() for t in threads]

    ids = ",".join(map(str, req_ids))
    cur.execute(f"SELECT COUNT(*), COUNT(DISTINCT unit_id) FROM request_allocation WHERE request_id IN ({ids})")
    total, distinct = cur.fetchone()
    cur.execute(f"SELECT COUNT(*) FROM patient_request WHERE request_id IN ({ids}) AND status = 'FULFILLED'")
    fulfilled = cur.fetchone()[0]

    print(f"allocations={total}  distinct units={distinct}  fulfilled={fulfilled}  errors={len(errors)}")
    print("PASS no double issue" if total == distinct else "FAIL double issue!")
    print("PASS expected served count" if fulfilled == min(N_REQ, usable) else "FAIL unexpected served count")
    print("PASS no errors/deadlocks" if not errors else f"FAIL {errors[:3]}")
