-- =====================================================================
-- 02_config_triggers_scheduler.sql
-- Business constants, integrity/expiry triggers, hourly expiry job
-- =====================================================================

CREATE OR REPLACE PACKAGE blood_cfg AS
  shelf_life_days    CONSTANT NUMBER := 42;  -- red cell shelf life
  near_expiry_days   CONSTANT NUMBER := 7;   -- flag NEAR_EXPIRY inside this window
  donation_gap_days  CONSTANT NUMBER := 90;  -- minimum gap between donations
  min_transit_days   CONSTANT NUMBER := 1;   -- don't ship a unit that would expire in transit
END blood_cfg;
/

-- ---------------------------------------------------------------------
-- TRIGGER 1: expiry + status-transition guard on every insert/update
--   * fills expiry_date if missing
--   * terminal states (ISSUED/EXPIRED/DISCARDED) can never be reopened
--   * an expired unit can never be issued
--   * AVAILABLE <-> NEAR_EXPIRY <-> EXPIRED recalculated from expiry_date
-- ---------------------------------------------------------------------
CREATE OR REPLACE TRIGGER trg_blood_unit_biu
BEFORE INSERT OR UPDATE ON blood_unit
FOR EACH ROW
BEGIN
  IF INSERTING THEN
    IF :NEW.expiry_date IS NULL THEN
      :NEW.expiry_date := :NEW.collection_date + blood_cfg.shelf_life_days;
    END IF;
  ELSIF :OLD.status IN ('ISSUED','EXPIRED','DISCARDED') AND :NEW.status <> :OLD.status THEN
    RAISE_APPLICATION_ERROR(-20001,
      'Unit ' || :OLD.unit_id || ' is ' || :OLD.status || ' and cannot change status');
  END IF;

  IF :NEW.status = 'ISSUED' AND :NEW.expiry_date <= SYSDATE
     AND (INSERTING OR :OLD.status <> 'ISSUED') THEN
    RAISE_APPLICATION_ERROR(-20002, 'Unit ' || :NEW.unit_id || ' is expired and cannot be issued');
  END IF;

  IF :NEW.status IN ('AVAILABLE','NEAR_EXPIRY') THEN
    :NEW.status := CASE
                     WHEN :NEW.expiry_date <= SYSDATE                            THEN 'EXPIRED'
                     WHEN :NEW.expiry_date <= SYSDATE + blood_cfg.near_expiry_days THEN 'NEAR_EXPIRY'
                     ELSE 'AVAILABLE'
                   END;
  END IF;
END;
/

-- TRIGGER 2: audit trail of every status change
CREATE OR REPLACE TRIGGER trg_blood_unit_log
AFTER INSERT OR UPDATE OF status ON blood_unit
FOR EACH ROW
DECLARE
  v_old VARCHAR2(12);
BEGIN
  IF INSERTING THEN
    v_old := NULL;
  ELSE
    v_old := :OLD.status;
  END IF;
  IF INSERTING OR v_old <> :NEW.status THEN
    INSERT INTO unit_status_log (unit_id, old_status, new_status)
    VALUES (:NEW.unit_id, v_old, :NEW.status);
  END IF;
END;
/

-- TRIGGER 3: DB-level safety net - an allocation must be blood-group compatible
CREATE OR REPLACE TRIGGER trg_allocation_compat
BEFORE INSERT ON request_allocation
FOR EACH ROW
DECLARE
  v_ok NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_ok
  FROM   patient_request r
         JOIN blood_unit u  ON u.unit_id  = :NEW.unit_id
         JOIN donor d       ON d.donor_id = u.donor_id
         JOIN blood_compatibility bc
              ON bc.recipient_group_id = r.group_id AND bc.donor_group_id = d.group_id
  WHERE  r.request_id = :NEW.request_id;

  IF v_ok = 0 THEN
    RAISE_APPLICATION_ERROR(-20003,
      'Unit ' || :NEW.unit_id || ' is not blood-group compatible with request ' || :NEW.request_id);
  END IF;
END;
/

-- ---------------------------------------------------------------------
-- Scheduled sweep (the procedure is defined in 03_procedures.sql, so the
-- job is created there). See bottom of 03_procedures.sql.
-- ---------------------------------------------------------------------
