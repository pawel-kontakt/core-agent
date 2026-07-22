-- =============================================================================
-- G5 — BATCH: duress alerts WITHOUT security presence
-- =============================================================================
-- Population variant of query.sql. For a time window and a set of campuses,
-- lists every location-based duress (BUTTON_CLICK) alert for which NO security
-- officer was anywhere in the alert's department during its response window
-- [triggered_at, resolved_at], plus per-campus rates.
--
-- "Security" = entity_metadata.entity_healthcare_role = 'SECURITY' (spans BOTH
-- the "Security" and generic "Staff" entity_type_ids — never filter by type).
-- Presence is read from entity_visits (the daily entity_location_activity table
-- is whole-day binary and cannot answer "present at the alert"; see report.md).
--
-- Parameters (edit here):
--   :start_ts / :end_ts  — window (end exclusive)
--   campus id list       — inline in t_alerts WHERE (5 ids)
--
-- Run:
--   set -a; source ../.env.prod-hca-fork; set +a; export PGSSLMODE=require
--   psql "$PG_DSN" -f query_batch.sql
--
-- Performance: entity_visits is a TimescaleDB hypertable. We bound its scan with
-- LITERAL window constants (chunk pruning) and stage results into indexed temp
-- tables, so the 711-alert presence check is 711 index probes, not a 6M-row
-- range join. Needs a raised statement_timeout for the visits materialisation.
-- =============================================================================

\set start_ts '2026-02-01 00:00:00+00'
\set end_ts   '2026-03-03 00:00:00+00'

\pset pager off
\timing on
SET statement_timeout = '590s';

-- ---- 1. Target duress alerts ------------------------------------------------
DROP TABLE IF EXISTS t_alerts;
CREATE TEMP TABLE t_alerts AS
SELECT uuid, created_at, company_id, campus_id, campus_name,
       floor_id, COALESCE(department_id, '') AS department_id,
       department_name, room_id, room_name,
       trigger_entity_name, status, resolution_code,
       COALESCE(triggered_at, created_at)                                      AS t_start,
       COALESCE(resolved_at, closed_at,
                COALESCE(triggered_at, created_at) + interval '30 min')        AS t_end
FROM alert
WHERE created_at >= :'start_ts'::timestamptz
  AND created_at <  :'end_ts'::timestamptz
  AND type = 'BUTTON_CLICK'
  AND campus_id IN (996734, 1295435, 205156, 1228155, 95155)
  AND room_id IS NOT NULL;
CREATE INDEX ON t_alerts (floor_id, department_id);

-- ---- 2. Security visits in target departments during the window -------------
--        Restricted to (floor, department) pairs that actually have a target
--        alert; window bounds are literals for hypertable chunk pruning.
DROP TABLE IF EXISTS t_sv;
CREATE TEMP TABLE t_sv AS
SELECT rm.floor_id, COALESCE(rm.department_id, '') AS department_id, v.start_time
FROM entity_visits v
JOIN entity_metadata em ON em.entity_id = v.entity_id
     AND em.entity_healthcare_role = 'SECURITY'
     AND em.company_id IN (SELECT DISTINCT company_id FROM t_alerts)
JOIN room_metadata rm ON rm.room_id = v.room_id
WHERE v.start_time >= :'start_ts'::timestamptz
  AND v.start_time <  :'end_ts'::timestamptz
  AND v.position_change_type <> 'POSITION_LOST'
  AND (rm.floor_id, COALESCE(rm.department_id, ''))
      IN (SELECT floor_id, department_id FROM t_alerts);
CREATE INDEX ON t_sv (floor_id, department_id, start_time);

-- ---- 3a. Per-campus summary -------------------------------------------------
\echo '==== Per-campus: duress alerts without security in department ===='
SELECT a.campus_id, a.campus_name,
       COUNT(*)                                              AS duress_alerts,
       COUNT(*) FILTER (WHERE nosec.uuid IS NOT NULL)        AS without_security,
       ROUND(100.0 * COUNT(*) FILTER (WHERE nosec.uuid IS NOT NULL) / COUNT(*), 1)
                                                             AS pct_without_security
FROM t_alerts a
LEFT JOIN LATERAL (
    SELECT a.uuid
    WHERE NOT EXISTS (
        SELECT 1 FROM t_sv s
        WHERE s.floor_id = a.floor_id
          AND s.department_id = a.department_id
          AND s.start_time BETWEEN a.t_start AND a.t_end
    )
) nosec ON TRUE
GROUP BY a.campus_id, a.campus_name
ORDER BY without_security DESC;

-- ---- 3b. The alerts without security presence (detail) ----------------------
\echo '==== Detail: alerts with NO security in department during response window ===='
SELECT a.uuid, a.created_at, a.campus_name, a.floor_id, a.department_name,
       a.room_name, a.trigger_entity_name, a.status, a.resolution_code,
       ROUND(EXTRACT(epoch FROM (a.t_end - a.t_start)))      AS window_secs
FROM t_alerts a
WHERE NOT EXISTS (
    SELECT 1 FROM t_sv s
    WHERE s.floor_id = a.floor_id
      AND s.department_id = a.department_id
      AND s.start_time BETWEEN a.t_start AND a.t_end
)
ORDER BY a.campus_name, a.created_at;
