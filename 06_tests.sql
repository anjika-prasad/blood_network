-- =====================================================================
-- 06_tests.sql  |  Test scenarios (run AFTER 01-05)
-- WARNING: wipes transactional data (units, requests, allocations,
-- transfers, logs). Hospitals, groups and donors are kept.
-- Output: PASS / FAIL lines via DBMS_OUTPUT.
-- =====================================================================
SET SERVEROUTPUT ON SIZE UNLIMITED

-- ---------- helpers --------------------------------------------------
CREATE OR REPLACE PROCEDURE test_reset AS
BEGIN
  DELETE FROM request_allocation;
  DELETE FROM blood_transfer;
  DELETE FROM unit_status_log;
  DELETE FROM patient_request;
  DELETE FROM blood_unit;
  COMMIT;
END;
/
CREATE OR REPLACE PROCEDURE test_add_unit(
  p_group IN VARCHAR2, p_hospital IN NUMBER, p_age_days IN NUMBER, p_unit_id OUT NUMBER) AS
  v_donor NUMBER;
BEGIN
  SELECT MIN(d.donor_id) INTO v_donor
  FROM donor d JOIN blood_group g ON g.group_id = d.group_id WHERE g.group_name = p_group;
  INSERT INTO blood_unit (donor_id, hospital_id, collection_date)
  VALUES (v_donor, p_hospital, TRUNC(SYSDATE) - p_age_days)
  RETURNING unit_id INTO p_unit_id;
END;
/
CREATE OR REPLACE PROCEDURE test_add_request(
  p_group IN VARCHAR2, p_hospital IN NUMBER, p_units IN NUMBER, p_req_id OUT NUMBER) AS
  v_gid NUMBER;
BEGIN
  SELECT group_id INTO v_gid FROM blood_group WHERE group_name = p_group;
  INSERT INTO patient_request (hospital_id, patient_ref, group_id, units_required)
  VALUES (p_hospital, 'TEST-PATIENT', v_gid, p_units)
  RETURNING request_id INTO p_req_id;
END;
/
CREATE OR REPLACE PROCEDURE test_assert(p_name IN VARCHAR2, p_ok IN BOOLEAN) AS
BEGIN
  DBMS_OUTPUT.PUT_LINE(CASE WHEN p_ok THEN 'PASS  ' ELSE 'FAIL  ' END || p_name);
END;
/
CREATE OR REPLACE FUNCTION test_unit_status(p_id NUMBER) RETURN VARCHAR2 AS v VARCHAR2(12);
BEGIN SELECT status INTO v FROM blood_unit WHERE unit_id = p_id; RETURN v; END;
/
CREATE OR REPLACE FUNCTION test_req_status(p_id NUMBER) RETURN VARCHAR2 AS v VARCHAR2(16);
BEGIN SELECT status INTO v FROM patient_request WHERE request_id = p_id; RETURN v; END;
/
-- Runs allocate_request in its OWN transaction (simulates a second user session)
CREATE OR REPLACE PROCEDURE test_allocate_autonomous(p_req IN NUMBER) AS
  PRAGMA AUTONOMOUS_TRANSACTION;
BEGIN
  allocate_request(p_req, 'N');
  COMMIT;
END;
/

-- =====================================================================
-- T0  Donation intake rules
-- =====================================================================
DECLARE
  v_unit NUMBER; v_donor NUMBER; v_exp DATE;
BEGIN
  test_reset;
  SELECT MIN(donor_id) INTO v_donor FROM donor;
  UPDATE donor SET last_donation_date = NULL WHERE donor_id = v_donor;
  record_donation(v_donor, 1, 350, v_unit);
  SELECT expiry_date INTO v_exp FROM blood_unit WHERE unit_id = v_unit;
  test_assert('T0a donation creates unit with expiry = collection + 42 days',
              TRUNC(v_exp) = TRUNC(SYSDATE) + blood_cfg.shelf_life_days);
  BEGIN
    record_donation(v_donor, 1, 350, v_unit);
    test_assert('T0b second donation within 90 days is rejected', FALSE);
  EXCEPTION WHEN OTHERS THEN
    test_assert('T0b second donation within 90 days is rejected', SQLCODE = -20020);
  END;
  ROLLBACK;
END;
/

-- =====================================================================
-- T1  FEFO: the two OLDEST compatible units are issued, freshest kept
-- =====================================================================
DECLARE
  u_new NUMBER; u_old NUMBER; u_mid NUMBER; r NUMBER; v_cnt NUMBER;
BEGIN
  test_reset;
  test_add_unit('A+', 1, 10, u_new);
  test_add_unit('A+', 1, 30, u_old);
  test_add_unit('A+', 1, 20, u_mid);
  test_add_request('A+', 1, 2, r);
  allocate_request(r);
  SELECT COUNT(*) INTO v_cnt FROM request_allocation WHERE request_id = r AND unit_id IN (u_old, u_mid);
  test_assert('T1a FEFO issues the two units closest to expiry', v_cnt = 2);
  test_assert('T1b freshest unit stays AVAILABLE', test_unit_status(u_new) = 'AVAILABLE');
  test_assert('T1c request becomes FULFILLED', test_req_status(r) = 'FULFILLED');
  COMMIT;
END;
/

-- =====================================================================
-- T2  Compatibility: incompatible units are never used
-- =====================================================================
DECLARE
  u_bpos NUMBER; u_opos NUMBER; u_oneg NUMBER; r NUMBER; v_cnt NUMBER; v_alloc NUMBER;
BEGIN
  test_reset;
  test_add_unit('B+', 2, 5, u_bpos);
  test_add_unit('O+', 2, 5, u_opos);
  test_add_request('A-', 2, 1, r);          -- A- can only receive O- or A-
  allocate_request(r);
  SELECT COUNT(*) INTO v_cnt FROM request_allocation WHERE request_id = r;
  test_assert('T2a A- patient gets nothing from B+/O+ stock', v_cnt = 0 AND test_req_status(r) = 'PENDING');
  test_add_unit('O-', 2, 8, u_oneg);
  allocate_request(r);
  SELECT unit_id INTO v_alloc FROM request_allocation WHERE request_id = r;
  test_assert('T2b once O- arrives, it is issued to the A- patient', v_alloc = u_oneg);
  test_assert('T2c incompatible units untouched',
              test_unit_status(u_bpos) <> 'ISSUED' AND test_unit_status(u_opos) <> 'ISSUED');
  COMMIT;
END;
/

-- =====================================================================
-- T3  Expired units: never issued; illegal status changes rejected;
--     incompatible manual allocation rejected by trigger
-- =====================================================================
DECLARE
  u_exp NUMBER; u_ap NUMBER; r NUMBER; r2 NUMBER; v_cnt NUMBER;
BEGIN
  test_reset;
  test_add_unit('O+', 1, 50, u_exp);        -- 50 days old => already expired
  test_assert('T3a expired unit is auto-flagged EXPIRED on insert', test_unit_status(u_exp) = 'EXPIRED');
  test_add_request('O+', 1, 1, r);
  allocate_request(r, 'N');
  SELECT COUNT(*) INTO v_cnt FROM request_allocation WHERE request_id = r;
  test_assert('T3b expired unit is never allocated', v_cnt = 0);
  BEGIN
    UPDATE blood_unit SET status = 'ISSUED' WHERE unit_id = u_exp;
    test_assert('T3c EXPIRED -> ISSUED is blocked', FALSE);
  EXCEPTION WHEN OTHERS THEN
    test_assert('T3c EXPIRED -> ISSUED is blocked', SQLCODE IN (-20001, -20002));
  END;
  test_add_unit('A+', 1, 3, u_ap);
  test_add_request('O-', 1, 1, r2);         -- O- patient can only take O- blood
  BEGIN
    INSERT INTO request_allocation (request_id, unit_id) VALUES (r2, u_ap);
    test_assert('T3d incompatible allocation rejected by trigger', FALSE);
  EXCEPTION WHEN OTHERS THEN
    test_assert('T3d incompatible allocation rejected by trigger', SQLCODE = -20003);
  END;
  ROLLBACK;
END;
/

-- =====================================================================
-- T4  Scheduled sweep: catches units whose status went stale
--     (we disable the row trigger to simulate "time passing, no DML")
-- =====================================================================
DECLARE
  u_a NUMBER; u_b NUMBER; u_c NUMBER; v_donor NUMBER;
  PROCEDURE ins(p_days_left IN NUMBER, p_id OUT NUMBER) IS
  BEGIN
    INSERT INTO blood_unit (donor_id, hospital_id, collection_date, expiry_date, status)
    VALUES (v_donor, 1, SYSDATE + p_days_left - 42, SYSDATE + p_days_left, 'AVAILABLE')
    RETURNING unit_id INTO p_id;
  END;
BEGIN
  test_reset;
  SELECT MIN(donor_id) INTO v_donor FROM donor;
  EXECUTE IMMEDIATE 'ALTER TRIGGER trg_blood_unit_biu DISABLE';
  ins(-1, u_a);  ins(3, u_b);  ins(30, u_c);
  COMMIT;
  EXECUTE IMMEDIATE 'ALTER TRIGGER trg_blood_unit_biu ENABLE';
  test_assert('T4pre units start with stale AVAILABLE status', test_unit_status(u_a) = 'AVAILABLE');
  sweep_expiry;
  test_assert('T4a past-expiry unit -> EXPIRED',          test_unit_status(u_a) = 'EXPIRED');
  test_assert('T4b expiring in 3 days -> NEAR_EXPIRY',    test_unit_status(u_b) = 'NEAR_EXPIRY');
  test_assert('T4c expiring in 30 days stays AVAILABLE',  test_unit_status(u_c) = 'AVAILABLE');
EXCEPTION WHEN OTHERS THEN
  EXECUTE IMMEDIATE 'ALTER TRIGGER trg_blood_unit_biu ENABLE';
  RAISE;
END;
/

-- =====================================================================
-- T5  Shortage -> network transfer, network-wide FEFO
--     Hospital 1 has no B-. Hospital 2 has B- units (7, 17, 37 days left).
-- =====================================================================
DECLARE
  u_7 NUMBER; u_17 NUMBER; u_37 NUMBER; r NUMBER; v_cnt NUMBER;
BEGIN
  test_reset;
  test_add_unit('B-', 2, 35, u_7);
  test_add_unit('B-', 2, 25, u_17);
  test_add_unit('B-', 2, 5,  u_37);
  test_add_request('B-', 1, 2, r);
  allocate_request(r);
  SELECT COUNT(*) INTO v_cnt FROM blood_transfer
   WHERE request_id = r AND status = 'IN_TRANSIT' AND unit_id IN (u_7, u_17);
  test_assert('T5a shortfall triggers transfers of the two soonest-expiring units', v_cnt = 2);
  test_assert('T5b request is TRANSFER_PENDING', test_req_status(r) = 'TRANSFER_PENDING');
  test_assert('T5c shipped units are IN_TRANSIT (cannot be double-booked)',
              test_unit_status(u_7) = 'IN_TRANSIT' AND test_unit_status(u_17) = 'IN_TRANSIT');
  FOR t IN (SELECT transfer_id FROM blood_transfer WHERE request_id = r) LOOP
    receive_transfer(t.transfer_id);
  END LOOP;
  test_assert('T5d after receipt the request is FULFILLED', test_req_status(r) = 'FULFILLED');
  SELECT COUNT(*) INTO v_cnt FROM blood_unit
   WHERE unit_id IN (u_7, u_17) AND hospital_id = 1 AND status = 'ISSUED';
  test_assert('T5e units now belong to the receiving hospital and are ISSUED', v_cnt = 2);
  test_assert('T5f freshest unit stayed at the sender', test_unit_status(u_37) = 'AVAILABLE');
  COMMIT;
END;
/

-- =====================================================================
-- T6  Concurrency: two "sessions" compete for the same blood group.
--     Session 1 (this block) locks the oldest unit and does NOT commit.
--     Session 2 (autonomous transaction) must SKIP it, not wait/double-issue.
-- =====================================================================
DECLARE
  u_old NUMBER; u_new NUMBER; r1 NUMBER; r2 NUMBER; a1 NUMBER; a2 NUMBER;
BEGIN
  test_reset;
  test_add_unit('O+', 3, 25, u_old);
  test_add_unit('O+', 3, 20, u_new);
  test_add_request('O+', 3, 1, r1);
  test_add_request('O+', 3, 1, r2);
  COMMIT;                                   -- make setup visible to session 2

  allocate_request(r1, 'N');                -- session 1: holds row lock on u_old, uncommitted
  test_allocate_autonomous(r2);             -- session 2: runs concurrently, commits

  SELECT unit_id INTO a1 FROM request_allocation WHERE request_id = r1;
  SELECT unit_id INTO a2 FROM request_allocation WHERE request_id = r2;
  test_assert('T6a session 1 got the oldest unit (FEFO)', a1 = u_old);
  test_assert('T6b session 2 skipped the locked unit and got the next one', a2 = u_new);
  test_assert('T6c no unit issued to two patients', a1 <> a2);
  COMMIT;
END;
/
-- Without SKIP LOCKED, session 2 would have blocked on session 1's lock (here: a deadlock,
-- ORA-00060). With plain SELECT and no locking, both would have picked the same unit and the
-- UNIQUE(unit_id) constraint on request_allocation would have been the last line of defence.

-- =====================================================================
-- T7  Evaluation: FEFO vs naive policy on IDENTICAL data
--     Metric: usable units still sitting in stock that expire within 7 days
--     (= units about to be wasted) after serving the same 70 requests.
--     ROLLBACK TO SAVEPOINT resets the data between the two runs.
-- =====================================================================
DECLARE
  TYPE t_ids IS TABLE OF NUMBER;
  v_reqs t_ids := t_ids();
  v_donor NUMBER; v_r NUMBER; v_id NUMBER; v_base NUMBER; v_gid NUMBER;
  v_risk_fefo NUMBER; v_risk_fifo NUMBER;

  FUNCTION f_group RETURN NUMBER IS v NUMBER := DBMS_RANDOM.VALUE(0, 100);
  BEGIN
    RETURN CASE WHEN v < 36 THEN 2 WHEN v < 64 THEN 4 WHEN v < 85 THEN 6 WHEN v < 90 THEN 8
                WHEN v < 93 THEN 1 WHEN v < 96 THEN 3 WHEN v < 98 THEN 5 ELSE 7 END;
  END;

  PROCEDURE run_policy(p_policy IN VARCHAR2, p_risk OUT NUMBER) IS
    v_done NUMBER;
  BEGIN
    SAVEPOINT before_run;
    FOR i IN 1 .. v_reqs.COUNT LOOP
      allocate_request(v_reqs(i), 'Y', p_policy);
    END LOOP;
    SELECT COUNT(*) INTO p_risk FROM blood_unit
     WHERE status IN ('AVAILABLE','NEAR_EXPIRY')
       AND expiry_date <= SYSDATE + blood_cfg.near_expiry_days;
    SELECT COUNT(*) INTO v_done FROM patient_request WHERE status IN ('FULFILLED','TRANSFER_PENDING');
    DBMS_OUTPUT.PUT_LINE(RPAD(p_policy, 5) || ': requests served/in transit = ' || v_done
                         || ' | units about to expire unused = ' || p_risk);
    ROLLBACK TO before_run;
  END;
BEGIN
  test_reset;
  DBMS_RANDOM.SEED(7);
  FOR i IN 1 .. 160 LOOP
    SELECT donor_id INTO v_donor FROM (SELECT donor_id FROM donor ORDER BY DBMS_RANDOM.VALUE) WHERE ROWNUM = 1;
    v_r := DBMS_RANDOM.VALUE(0, 100);
    INSERT INTO blood_unit (donor_id, hospital_id, collection_date)
    VALUES (v_donor,
            CASE WHEN v_r < 45 THEN 1 WHEN v_r < 75 THEN 2 WHEN v_r < 90 THEN 3 ELSE 4 END,
            TRUNC(SYSDATE) - TRUNC(DBMS_RANDOM.VALUE(0, 41)));
  END LOOP;
  FOR i IN 1 .. 70 LOOP
    v_gid := f_group;
    INSERT INTO patient_request (hospital_id, patient_ref, group_id, units_required)
    VALUES (TRUNC(DBMS_RANDOM.VALUE(1, 5)), 'SIM-' || i, v_gid, TRUNC(DBMS_RANDOM.VALUE(1, 3)))
    RETURNING request_id INTO v_id;
    v_reqs.EXTEND; v_reqs(v_reqs.LAST) := v_id;
  END LOOP;
  COMMIT;

  SELECT COUNT(*) INTO v_base FROM blood_unit
   WHERE status IN ('AVAILABLE','NEAR_EXPIRY') AND expiry_date <= SYSDATE + blood_cfg.near_expiry_days;
  DBMS_OUTPUT.PUT_LINE('Before any allocation: units expiring within 7 days = ' || v_base);

  run_policy('FIFO', v_risk_fifo);   -- naive baseline: arrival order, ignores expiry
  run_policy('FEFO', v_risk_fefo);   -- this project's policy
  test_assert('T7 FEFO leaves fewer units about to expire than naive allocation (' ||
              v_risk_fefo || ' vs ' || v_risk_fifo || ')', v_risk_fefo <= v_risk_fifo);
END;
/

-- =====================================================================
-- Index usage: the FEFO candidate query should use IX_UNIT_FEFO
-- =====================================================================
EXPLAIN PLAN FOR
SELECT u.unit_id
FROM   blood_unit u
WHERE  u.hospital_id = 1 AND u.status IN ('AVAILABLE','NEAR_EXPIRY') AND u.expiry_date > SYSDATE
ORDER  BY u.expiry_date;
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);
