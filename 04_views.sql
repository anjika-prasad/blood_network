-- =====================================================================
-- 04_views.sql  |  Network-wide, real-time dashboards
-- "Usable" always re-checks expiry_date > SYSDATE, so the dashboard is
-- correct even between scheduled sweeps.
-- =====================================================================

-- Base view: every unit with its group, hospital and days left
CREATE OR REPLACE VIEW v_unit_detail AS
SELECT u.unit_id, u.hospital_id, h.hospital_name, d.group_id, g.group_name,
       u.collection_date, u.expiry_date,
       ROUND(u.expiry_date - SYSDATE, 1) AS days_to_expiry,
       u.status
FROM   blood_unit u
       JOIN donor d       ON d.donor_id    = u.donor_id
       JOIN blood_group g ON g.group_id    = d.group_id
       JOIN hospital h    ON h.hospital_id = u.hospital_id;

-- Stock per hospital per group (zero rows included)
CREATE OR REPLACE VIEW v_hospital_stock AS
SELECT h.hospital_id, h.hospital_name, g.group_id, g.group_name,
       NVL(s.usable_units, 0)      AS usable_units,
       NVL(s.near_expiry_units, 0) AS near_expiry_units
FROM   hospital h
       CROSS JOIN blood_group g
       LEFT JOIN (
         SELECT u.hospital_id, d.group_id,
                SUM(CASE WHEN u.status IN ('AVAILABLE','NEAR_EXPIRY') AND u.expiry_date > SYSDATE
                         THEN 1 ELSE 0 END) AS usable_units,
                SUM(CASE WHEN u.status IN ('AVAILABLE','NEAR_EXPIRY') AND u.expiry_date > SYSDATE
                          AND u.expiry_date <= SYSDATE + 7
                         THEN 1 ELSE 0 END) AS near_expiry_units
         FROM   blood_unit u JOIN donor d ON d.donor_id = u.donor_id
         GROUP  BY u.hospital_id, d.group_id
       ) s ON s.hospital_id = h.hospital_id AND s.group_id = g.group_id
WHERE  h.is_active = 'Y';

-- Units still needed by open requests, per hospital per recipient group
CREATE OR REPLACE VIEW v_open_demand AS
SELECT r.hospital_id, r.group_id,
       SUM(r.units_required - NVL(a.alloc, 0)) AS units_needed
FROM   patient_request r
       LEFT JOIN (SELECT request_id, COUNT(*) AS alloc
                  FROM request_allocation GROUP BY request_id) a
              ON a.request_id = r.request_id
WHERE  r.status IN ('PENDING','PARTIAL','TRANSFER_PENDING')
GROUP  BY r.hospital_id, r.group_id;

-- Shortage / surplus flag per hospital per group
CREATE OR REPLACE VIEW v_shortage_surplus AS
SELECT s.hospital_id, s.hospital_name, s.group_name,
       s.usable_units,
       NVL(dm.units_needed, 0)                     AS open_demand,
       s.usable_units - NVL(dm.units_needed, 0)    AS net_available,
       st.min_level, st.max_level,
       CASE WHEN s.usable_units - NVL(dm.units_needed, 0) < st.min_level THEN 'SHORTAGE'
            WHEN s.usable_units > st.max_level                           THEN 'SURPLUS'
            ELSE 'OK' END                          AS stock_flag
FROM   v_hospital_stock s
       JOIN stock_threshold st ON st.hospital_id = s.hospital_id AND st.group_id = s.group_id
       LEFT JOIN v_open_demand dm ON dm.hospital_id = s.hospital_id AND dm.group_id = s.group_id;

-- Whole-network summary per blood group
CREATE OR REPLACE VIEW v_network_summary AS
SELECT group_name,
       SUM(usable_units)                                    AS network_usable,
       SUM(open_demand)                                     AS network_demand,
       SUM(CASE WHEN stock_flag = 'SHORTAGE' THEN 1 ELSE 0 END) AS hospitals_short,
       SUM(CASE WHEN stock_flag = 'SURPLUS'  THEN 1 ELSE 0 END) AS hospitals_surplus
FROM   v_shortage_surplus
GROUP  BY group_name;

-- Units that will expire within 7 days (candidates for transfer / priority use)
CREATE OR REPLACE VIEW v_expiring_soon AS
SELECT unit_id, hospital_name, group_name, expiry_date, days_to_expiry
FROM   v_unit_detail
WHERE  status IN ('AVAILABLE','NEAR_EXPIRY')
AND    expiry_date > SYSDATE
AND    expiry_date <= SYSDATE + 7;

-- Wastage per hospital: expired / (expired + issued)
CREATE OR REPLACE VIEW v_wastage_report AS
SELECT hospital_name,
       SUM(CASE WHEN status = 'ISSUED'  THEN 1 ELSE 0 END) AS units_issued,
       SUM(CASE WHEN status = 'EXPIRED' THEN 1 ELSE 0 END) AS units_expired,
       ROUND(100 * SUM(CASE WHEN status = 'EXPIRED' THEN 1 ELSE 0 END)
             / NULLIF(SUM(CASE WHEN status IN ('ISSUED','EXPIRED') THEN 1 ELSE 0 END), 0), 1)
                                                            AS wastage_pct
FROM   v_unit_detail
GROUP  BY hospital_name;

-- Request fulfilment speed
CREATE OR REPLACE VIEW v_request_fulfilment AS
SELECT r.request_id, h.hospital_name, g.group_name, r.units_required, r.urgency,
       r.status, r.request_time, r.fulfilled_at,
       ROUND((r.fulfilled_at - r.request_time) * 24 * 60, 1) AS minutes_to_fulfil
FROM   patient_request r
       JOIN hospital h    ON h.hospital_id = r.hospital_id
       JOIN blood_group g ON g.group_id    = r.group_id;
