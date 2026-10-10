-- =====================================================================
-- 03_procedures.sql
-- Allocation (FEFO + compatibility), transfers, donation intake,
-- expiry sweep, and the scheduler job.
--
-- TRANSACTION RULE: allocate_request / request_network_transfer /
-- receive_transfer / initiate_transfer / record_donation do NOT commit.
-- The caller owns the transaction (all-or-nothing). sweep_expiry commits
-- because it is a self-contained batch job.
-- =====================================================================

-- ---------------------------------------------------------------------
-- try_lock_unit: pessimistic row lock WITHOUT waiting.
-- FOR UPDATE SKIP LOCKED => if another session already holds the row,
-- we simply move on to the next-best unit instead of blocking/deadlocking.
-- Re-checks status + expiry after the lock is acquired.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION try_lock_unit(p_unit_id IN NUMBER) RETURN BOOLEAN AS
  v_id NUMBER;
BEGIN
  SELECT unit_id INTO v_id
  FROM   blood_unit
  WHERE  unit_id = p_unit_id
  AND    status IN ('AVAILABLE','NEAR_EXPIRY')
  AND    expiry_date > SYSDATE
  FOR UPDATE SKIP LOCKED;
  RETURN TRUE;
EXCEPTION
  WHEN NO_DATA_FOUND THEN RETURN FALSE;   -- locked by someone else, or no longer usable
END try_lock_unit;
/

-- ---------------------------------------------------------------------
-- refresh_request_status: derive request status from allocations/transfers
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE refresh_request_status(p_request_id IN NUMBER) AS
  v_req NUMBER; v_cur VARCHAR2(16); v_alloc NUMBER; v_transit NUMBER; v_new VARCHAR2(16);
BEGIN
  SELECT units_required, status INTO v_req, v_cur
  FROM   patient_request WHERE request_id = p_request_id;
  IF v_cur = 'CANCELLED' THEN RETURN; END IF;

  SELECT COUNT(*) INTO v_alloc   FROM request_allocation WHERE request_id = p_request_id;
  SELECT COUNT(*) INTO v_transit FROM blood_transfer
   WHERE request_id = p_request_id AND status = 'IN_TRANSIT';

  v_new := CASE WHEN v_alloc >= v_req THEN 'FULFILLED'
                WHEN v_transit > 0    THEN 'TRANSFER_PENDING'
                WHEN v_alloc > 0      THEN 'PARTIAL'
                ELSE 'PENDING' END;

  UPDATE patient_request
  SET    status       = v_new,
         fulfilled_at = CASE WHEN v_new = 'FULFILLED' THEN NVL(fulfilled_at, SYSDATE) ELSE fulfilled_at END
  WHERE  request_id = p_request_id;
END refresh_request_status;
/

-- ---------------------------------------------------------------------
-- request_network_transfer: cover a local shortfall from OTHER hospitals.
-- Network-wide FEFO: the soonest-to-expire compatible units anywhere are
-- shipped first (they would otherwise be wasted at the sender).
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE request_network_transfer(
  p_request_id  IN NUMBER,
  p_needed      IN NUMBER,
  p_to_hospital IN NUMBER,
  p_group_id    IN NUMBER,
  p_policy      IN VARCHAR2 DEFAULT 'FEFO')
AS
  v_got NUMBER := 0;
  CURSOR c_remote IS
    SELECT u.unit_id, u.hospital_id
    FROM   blood_unit u
           JOIN hospital h ON h.hospital_id = u.hospital_id AND h.is_active = 'Y'
           JOIN donor d    ON d.donor_id = u.donor_id
           JOIN blood_compatibility bc
                ON bc.donor_group_id = d.group_id AND bc.recipient_group_id = p_group_id
    WHERE  u.hospital_id <> p_to_hospital
    AND    u.status IN ('AVAILABLE','NEAR_EXPIRY')
    AND    u.expiry_date > SYSDATE + blood_cfg.min_transit_days
    ORDER  BY DECODE(p_policy, 'FEFO', u.expiry_date, DATE '2100-01-01'),
              CASE WHEN d.group_id = p_group_id THEN 0 ELSE 1 END,
              u.unit_id;
BEGIN
  FOR c IN c_remote LOOP
    EXIT WHEN v_got >= p_needed;
    IF try_lock_unit(c.unit_id) THEN
      UPDATE blood_unit SET status = 'IN_TRANSIT' WHERE unit_id = c.unit_id;
      INSERT INTO blood_transfer (unit_id, from_hospital_id, to_hospital_id, request_id)
      VALUES (c.unit_id, c.hospital_id, p_to_hospital, p_request_id);
      v_got := v_got + 1;
    END IF;
  END LOOP;
END request_network_transfer;
/

-- ---------------------------------------------------------------------
-- allocate_request: THE core procedure
--   1. lock the request row (serialises concurrent attempts on same request)
--   2. scan compatible local units in FEFO order (optimistic, no locks)
--   3. for each candidate: try_lock_unit (SKIP LOCKED) -> issue it
--   4. any shortfall -> request transfers from other hospitals
--   5. recompute request status
-- p_policy 'FIFO' exists only as a naive baseline for the evaluation.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE allocate_request(
  p_request_id     IN NUMBER,
  p_allow_transfer IN VARCHAR2 DEFAULT 'Y',
  p_policy         IN VARCHAR2 DEFAULT 'FEFO')
AS
  v_req     patient_request%ROWTYPE;
  v_have    NUMBER;
  v_transit NUMBER;
  v_need    NUMBER;
  v_got     NUMBER := 0;

  CURSOR c_local(p_hosp NUMBER, p_group NUMBER, p_pol VARCHAR2) IS
    SELECT u.unit_id
    FROM   blood_unit u
           JOIN donor d ON d.donor_id = u.donor_id
           JOIN blood_compatibility bc
                ON bc.donor_group_id = d.group_id AND bc.recipient_group_id = p_group
    WHERE  u.hospital_id = p_hosp
    AND    u.status IN ('AVAILABLE','NEAR_EXPIRY')
    AND    u.expiry_date > SYSDATE
    ORDER  BY DECODE(p_pol, 'FEFO', u.expiry_date, DATE '2100-01-01'),  -- first expiry, first out
              CASE WHEN d.group_id = p_group THEN 0 ELSE 1 END,         -- prefer exact match (save O-)
              u.unit_id;
BEGIN
  SELECT * INTO v_req FROM patient_request WHERE request_id = p_request_id FOR UPDATE;

  IF v_req.status IN ('FULFILLED','CANCELLED') THEN
    RAISE_APPLICATION_ERROR(-20010, 'Request ' || p_request_id || ' is already ' || v_req.status);
  END IF;

  SELECT COUNT(*) INTO v_have    FROM request_allocation WHERE request_id = p_request_id;
  SELECT COUNT(*) INTO v_transit FROM blood_transfer
   WHERE request_id = p_request_id AND status = 'IN_TRANSIT';
  v_need := v_req.units_required - v_have - v_transit;

  IF v_need > 0 THEN
    FOR c IN c_local(v_req.hospital_id, v_req.group_id, p_policy) LOOP
      EXIT WHEN v_got >= v_need;
      IF try_lock_unit(c.unit_id) THEN
        UPDATE blood_unit SET status = 'ISSUED' WHERE unit_id = c.unit_id;
        INSERT INTO request_allocation (request_id, unit_id) VALUES (p_request_id, c.unit_id);
        v_got := v_got + 1;
      END IF;
    END LOOP;

    v_need := v_need - v_got;
    IF v_need > 0 AND p_allow_transfer = 'Y' THEN
      request_network_transfer(p_request_id, v_need, v_req.hospital_id, v_req.group_id, p_policy);
    END IF;
  END IF;

  refresh_request_status(p_request_id);
END allocate_request;
/

-- ---------------------------------------------------------------------
-- receive_transfer: destination hospital confirms arrival.
-- Request-linked transfers are issued straight to the patient;
-- pure rebalancing transfers become stock at the destination.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE receive_transfer(p_transfer_id IN NUMBER) AS
  v_tr  blood_transfer%ROWTYPE;
  v_exp DATE;
BEGIN
  SELECT * INTO v_tr FROM blood_transfer WHERE transfer_id = p_transfer_id FOR UPDATE;
  IF v_tr.status <> 'IN_TRANSIT' THEN
    RAISE_APPLICATION_ERROR(-20011, 'Transfer ' || p_transfer_id || ' is already ' || v_tr.status);
  END IF;

  SELECT expiry_date INTO v_exp FROM blood_unit WHERE unit_id = v_tr.unit_id FOR UPDATE;

  IF v_exp <= SYSDATE THEN                       -- expired while travelling
    UPDATE blood_unit SET status = 'EXPIRED' WHERE unit_id = v_tr.unit_id;
    UPDATE blood_transfer SET status = 'CANCELLED', received_at = SYSDATE WHERE transfer_id = p_transfer_id;
  ELSIF v_tr.request_id IS NOT NULL THEN
    UPDATE blood_unit SET status = 'ISSUED', hospital_id = v_tr.to_hospital_id WHERE unit_id = v_tr.unit_id;
    INSERT INTO request_allocation (request_id, unit_id) VALUES (v_tr.request_id, v_tr.unit_id);
    UPDATE blood_transfer SET status = 'RECEIVED', received_at = SYSDATE WHERE transfer_id = p_transfer_id;
  ELSE
    UPDATE blood_unit SET status = 'AVAILABLE', hospital_id = v_tr.to_hospital_id WHERE unit_id = v_tr.unit_id;
    UPDATE blood_transfer SET status = 'RECEIVED', received_at = SYSDATE WHERE transfer_id = p_transfer_id;
  END IF;

  IF v_tr.request_id IS NOT NULL THEN
    refresh_request_status(v_tr.request_id);
  END IF;
END receive_transfer;
/

-- Manual rebalancing: move a surplus / near-expiry unit to a hospital that needs it
CREATE OR REPLACE PROCEDURE initiate_transfer(p_unit_id IN NUMBER, p_to_hospital IN NUMBER) AS
  v_from NUMBER;
BEGIN
  IF NOT try_lock_unit(p_unit_id) THEN
    RAISE_APPLICATION_ERROR(-20030, 'Unit ' || p_unit_id || ' is locked, expired or not available');
  END IF;
  SELECT hospital_id INTO v_from FROM blood_unit WHERE unit_id = p_unit_id;
  UPDATE blood_unit SET status = 'IN_TRANSIT' WHERE unit_id = p_unit_id;
  INSERT INTO blood_transfer (unit_id, from_hospital_id, to_hospital_id)
  VALUES (p_unit_id, v_from, p_to_hospital);
END initiate_transfer;
/

-- ---------------------------------------------------------------------
-- record_donation: intake of a new unit with donor eligibility checks
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE record_donation(
  p_donor_id    IN  NUMBER,
  p_hospital_id IN  NUMBER,
  p_volume_ml   IN  NUMBER DEFAULT 350,
  p_unit_id     OUT NUMBER)
AS
  v_dob DATE; v_last DATE; v_age NUMBER;
BEGIN
  SELECT date_of_birth, last_donation_date INTO v_dob, v_last
  FROM   donor WHERE donor_id = p_donor_id FOR UPDATE;

  v_age := MONTHS_BETWEEN(SYSDATE, v_dob) / 12;
  IF v_age < 18 OR v_age > 65 THEN
    RAISE_APPLICATION_ERROR(-20021, 'Donor ' || p_donor_id || ' is outside the 18-65 age range');
  END IF;
  IF v_last IS NOT NULL AND SYSDATE - v_last < blood_cfg.donation_gap_days THEN
    RAISE_APPLICATION_ERROR(-20020, 'Donor ' || p_donor_id || ' donated less than '
                            || blood_cfg.donation_gap_days || ' days ago');
  END IF;

  INSERT INTO blood_unit (donor_id, hospital_id, collection_date, volume_ml)
  VALUES (p_donor_id, p_hospital_id, SYSDATE, p_volume_ml)
  RETURNING unit_id INTO p_unit_id;

  UPDATE donor SET last_donation_date = SYSDATE WHERE donor_id = p_donor_id;
END record_donation;
/

-- ---------------------------------------------------------------------
-- sweep_expiry: batch job - mark expired, flag near-expiry, write a log row
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sweep_expiry AS
  v_expired NUMBER; v_near NUMBER;
BEGIN
  UPDATE blood_unit SET status = 'EXPIRED'
  WHERE  status IN ('AVAILABLE','NEAR_EXPIRY','IN_TRANSIT')
  AND    expiry_date <= SYSDATE;
  v_expired := SQL%ROWCOUNT;

  UPDATE blood_unit SET status = 'NEAR_EXPIRY'
  WHERE  status = 'AVAILABLE'
  AND    expiry_date <= SYSDATE + blood_cfg.near_expiry_days;
  v_near := SQL%ROWCOUNT;

  INSERT INTO expiry_sweep_log (flagged_near_expiry, marked_expired) VALUES (v_near, v_expired);
  COMMIT;
END sweep_expiry;
/

-- ---------------------------------------------------------------------
-- Scheduled event: run the sweep every hour.
-- Needs the CREATE JOB privilege:  GRANT CREATE JOB TO <your_user>;  (as DBA)
-- ---------------------------------------------------------------------
BEGIN
  BEGIN
    DBMS_SCHEDULER.DROP_JOB('JOB_EXPIRY_SWEEP', force => TRUE);
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  DBMS_SCHEDULER.CREATE_JOB(
    job_name        => 'JOB_EXPIRY_SWEEP',
    job_type        => 'STORED_PROCEDURE',
    job_action      => 'SWEEP_EXPIRY',
    start_date      => SYSTIMESTAMP,
    repeat_interval => 'FREQ=HOURLY;INTERVAL=1',
    enabled         => TRUE,
    comments        => 'Hourly: mark expired units and flag units nearing expiry');
END;
/
