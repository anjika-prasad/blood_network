-- =====================================================================
-- 01_schema.sql  |  Blood Inventory & Expiry-Aware Allocation (Oracle 12c+)
-- Normalised to 3NF. Safe to re-run: drops existing objects first.
-- =====================================================================

BEGIN
  FOR t IN (SELECT table_name FROM user_tables
            WHERE table_name IN ('EXPIRY_SWEEP_LOG','UNIT_STATUS_LOG','BLOOD_TRANSFER',
                                 'REQUEST_ALLOCATION','PATIENT_REQUEST','STOCK_THRESHOLD',
                                 'BLOOD_UNIT','DONOR','HOSPITAL','BLOOD_COMPATIBILITY','BLOOD_GROUP'))
  LOOP
    EXECUTE IMMEDIATE 'DROP TABLE ' || t.table_name || ' CASCADE CONSTRAINTS PURGE';
  END LOOP;
END;
/

-- ---------- Reference tables ----------------------------------------
CREATE TABLE blood_group (
  group_id    NUMBER(2)    PRIMARY KEY,
  abo         VARCHAR2(2)  NOT NULL CHECK (abo IN ('O','A','B','AB')),
  rh          CHAR(1)      NOT NULL CHECK (rh IN ('+','-')),
  group_name  VARCHAR2(3)  NOT NULL UNIQUE,
  CONSTRAINT uq_abo_rh UNIQUE (abo, rh)
);

-- Which DONOR group's red cells can be given to which RECIPIENT group
CREATE TABLE blood_compatibility (
  recipient_group_id NUMBER(2) NOT NULL REFERENCES blood_group(group_id),
  donor_group_id     NUMBER(2) NOT NULL REFERENCES blood_group(group_id),
  CONSTRAINT pk_blood_compat PRIMARY KEY (recipient_group_id, donor_group_id)
);

CREATE TABLE hospital (
  hospital_id    NUMBER(4)     PRIMARY KEY,
  hospital_name  VARCHAR2(100) NOT NULL UNIQUE,
  city           VARCHAR2(60)  NOT NULL,
  phone          VARCHAR2(15),
  is_active      CHAR(1)       DEFAULT 'Y' NOT NULL CHECK (is_active IN ('Y','N'))
);

-- Reorder level (min) and overstock level (max) per hospital per blood group
CREATE TABLE stock_threshold (
  hospital_id NUMBER(4) NOT NULL REFERENCES hospital(hospital_id),
  group_id    NUMBER(2) NOT NULL REFERENCES blood_group(group_id),
  min_level   NUMBER(3) NOT NULL CHECK (min_level >= 0),
  max_level   NUMBER(3) NOT NULL,
  CONSTRAINT pk_stock_threshold PRIMARY KEY (hospital_id, group_id),
  CONSTRAINT ck_threshold_range CHECK (max_level >= min_level)
);

-- ---------- Core entities -------------------------------------------
CREATE TABLE donor (
  donor_id            NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  full_name           VARCHAR2(100) NOT NULL,
  date_of_birth       DATE          NOT NULL,
  gender              CHAR(1)       NOT NULL CHECK (gender IN ('M','F','O')),
  phone               VARCHAR2(15)  NOT NULL UNIQUE,
  group_id            NUMBER(2)     NOT NULL REFERENCES blood_group(group_id),
  last_donation_date  DATE
);

-- NOTE: blood group is NOT stored here. It is determined by donor_id -> donor.group_id,
-- so storing it again would create a transitive dependency (violates 3NF).
-- expiry_date is filled by trigger (collection_date + shelf life) and kept stored so it can be indexed.
CREATE TABLE blood_unit (
  unit_id          NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  donor_id         NUMBER        NOT NULL REFERENCES donor(donor_id),
  hospital_id      NUMBER(4)     NOT NULL REFERENCES hospital(hospital_id),   -- current holder
  collection_date  DATE          NOT NULL,
  expiry_date      DATE          NOT NULL,
  volume_ml        NUMBER(4)     DEFAULT 350 NOT NULL CHECK (volume_ml BETWEEN 200 AND 500),
  status           VARCHAR2(12)  DEFAULT 'AVAILABLE' NOT NULL
                   CHECK (status IN ('AVAILABLE','NEAR_EXPIRY','IN_TRANSIT','ISSUED','EXPIRED','DISCARDED')),
  CONSTRAINT ck_unit_dates CHECK (expiry_date > collection_date)
);

CREATE TABLE patient_request (
  request_id      NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  hospital_id     NUMBER(4)    NOT NULL REFERENCES hospital(hospital_id),
  patient_ref     VARCHAR2(30) NOT NULL,                      -- anonymised patient id / MRN
  group_id        NUMBER(2)    NOT NULL REFERENCES blood_group(group_id),  -- RECIPIENT group
  units_required  NUMBER(2)    NOT NULL CHECK (units_required > 0),
  urgency         VARCHAR2(8)  DEFAULT 'ROUTINE' NOT NULL CHECK (urgency IN ('CRITICAL','URGENT','ROUTINE')),
  request_time    DATE         DEFAULT SYSDATE NOT NULL,
  status          VARCHAR2(16) DEFAULT 'PENDING' NOT NULL
                  CHECK (status IN ('PENDING','PARTIAL','TRANSFER_PENDING','FULFILLED','CANCELLED')),
  fulfilled_at    DATE
);

-- One unit can be allocated to at most one request (UNIQUE = last line of defence vs double issue)
CREATE TABLE request_allocation (
  allocation_id  NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  request_id     NUMBER NOT NULL REFERENCES patient_request(request_id),
  unit_id        NUMBER NOT NULL REFERENCES blood_unit(unit_id),
  allocated_at   DATE   DEFAULT SYSDATE NOT NULL,
  CONSTRAINT uq_allocation_unit UNIQUE (unit_id)
);

CREATE TABLE blood_transfer (
  transfer_id      NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  unit_id          NUMBER    NOT NULL REFERENCES blood_unit(unit_id),
  from_hospital_id NUMBER(4) NOT NULL REFERENCES hospital(hospital_id),
  to_hospital_id   NUMBER(4) NOT NULL REFERENCES hospital(hospital_id),
  request_id       NUMBER    REFERENCES patient_request(request_id),   -- NULL = pure rebalancing
  initiated_at     DATE      DEFAULT SYSDATE NOT NULL,
  received_at      DATE,
  status           VARCHAR2(10) DEFAULT 'IN_TRANSIT' NOT NULL
                   CHECK (status IN ('IN_TRANSIT','RECEIVED','CANCELLED')),
  CONSTRAINT ck_transfer_diff CHECK (from_hospital_id <> to_hospital_id)
);

-- ---------- Audit / monitoring --------------------------------------
CREATE TABLE unit_status_log (
  log_id      NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  unit_id     NUMBER       NOT NULL REFERENCES blood_unit(unit_id),
  old_status  VARCHAR2(12),
  new_status  VARCHAR2(12) NOT NULL,
  changed_at  DATE         DEFAULT SYSDATE NOT NULL
);

CREATE TABLE expiry_sweep_log (
  sweep_id             NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  run_time             TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
  flagged_near_expiry  NUMBER NOT NULL,
  marked_expired       NUMBER NOT NULL
);

-- ---------- Indexes (support FEFO scans, FK joins, dashboards) -------
-- FEFO candidate scan: hospital + status filter, ordered by expiry
CREATE INDEX ix_unit_fefo      ON blood_unit (hospital_id, status, expiry_date);
-- Expiry sweep / expiring-soon reports
CREATE INDEX ix_unit_expiry    ON blood_unit (status, expiry_date);
CREATE INDEX ix_unit_donor     ON blood_unit (donor_id);
CREATE INDEX ix_donor_group    ON donor (group_id);
CREATE INDEX ix_req_open       ON patient_request (hospital_id, status, group_id);
CREATE INDEX ix_alloc_request  ON request_allocation (request_id);
CREATE INDEX ix_transfer_req   ON blood_transfer (request_id, status);
CREATE INDEX ix_transfer_unit  ON blood_transfer (unit_id);
CREATE INDEX ix_log_unit       ON unit_status_log (unit_id);
-- A unit can be in only ONE open transfer at a time
CREATE UNIQUE INDEX uq_transfer_open ON blood_transfer (CASE WHEN status = 'IN_TRANSIT' THEN unit_id END);
