-- =============================================================================
-- G5 — Security presence per duress alert, CTE-flow variant (user-specified)
-- =============================================================================
-- Flow (all joins LEFT, so every alert survives and can be counted):
--   cte1_alerts   : alerts filtered by date, TEST excluded
--   cte2_activity : LEFT JOIN LATERAL entity_location_activity in the alert's
--                   department for the alert's local day (day-level screen).
--                   Alert timestamps (t_start/t_end/tz) are carried downstream.
--   cte3_security : LEFT JOIN entity_metadata to keep only entities whose
--                   healthcare role is SECURITY (sec_entity_id = NULL otherwise).
--   cte4_visits   : LEFT JOIN LATERAL entity_visits for that security entity,
--                   filtered to the alert's response window [t_start,t_end] and
--                   the alert's department -> confirms real presence at the alert.
--
-- Final: count alerts total / with security same-day / with security during the
-- response window / without.
--
-- "Security" is identified ONLY via entity_healthcare_role (spans the "Security"
-- and generic "Staff" entity_type_ids). entity_location_activity is a whole-day
-- binary screen; entity_visits gives the at-the-alert truth (see report.md).
--
-- Run:
--   set -a; source ../.env.prod-hca-fork; set +a; export PGSSLMODE=require
--   psql "$PG_DSN" -f query_flow.sql
--
-- Perf notes (TimescaleDB): both hypertable laterals carry LITERAL window bounds
-- (:'start_ts'/:'end_ts') so chunks are pruned; the per-alert bounds narrow
-- within. entity_visits is probed by (entity_id,start_time) index per security
-- entity; the visits lateral LIMITs to the first in-window in-dept hit.
-- =============================================================================

\set start_ts '2026-02-01 00:00:00+00'
\set end_ts   '2026-03-03 00:00:00+00'

\pset pager off
\timing on
SET statement_timeout = '590s';

WITH
-- 1. Alerts (date window, TEST excluded). Join room_metadata for campus tz.
cte1_alerts AS (
    SELECT a.uuid, a.campus_id, a.campus_name,
           a.floor_id, COALESCE(a.department_id, '') AS department_id,
           a.room_id, a.resolution_code,
           rm.campus_timezone                                              AS tz,
           COALESCE(a.triggered_at, a.created_at)                          AS t_start,
           COALESCE(a.resolved_at, a.closed_at,
                    COALESCE(a.triggered_at, a.created_at) + interval '30 min') AS t_end
    FROM alert a
    LEFT JOIN room_metadata rm ON rm.room_id = a.room_id
    WHERE a.created_at >= :'start_ts'::timestamptz
      AND a.created_at <  :'end_ts'::timestamptz
      AND a.resolution_code IS DISTINCT FROM 'TEST'
      -- established scope for this investigation (adjust as needed):
      AND a.type = 'BUTTON_CLICK'
      AND a.campus_id IN (996734, 1295435, 205156, 1228155, 95155)
      AND a.room_id IS NOT NULL
),
-- 2. Day-level presence screen: entities in the alert's dept on the alert's
--    local day. snapshot_time is the local-midnight instant stored as UTC wall
--    clock; coarse literal bounds prune chunks, the equality pins the day.
cte2_activity AS (
    SELECT c1.*, la.entity_id AS present_entity_id
    FROM cte1_alerts c1
    LEFT JOIN LATERAL (
        SELECT el.entity_id
        FROM entity_location_activity el
        WHERE el.floor_id = c1.floor_id
          AND COALESCE(el.department_id, '') = c1.department_id
          AND el.snapshot_time >= (:'start_ts'::timestamptz AT TIME ZONE 'UTC') - interval '1 day'
          AND el.snapshot_time <  (:'end_ts'::timestamptz   AT TIME ZONE 'UTC') + interval '1 day'
          AND el.snapshot_time = ((date_trunc('day', c1.t_start AT TIME ZONE c1.tz)
                                   AT TIME ZONE c1.tz) AT TIME ZONE 'UTC')
    ) la ON TRUE
),
-- 3. Keep only entities whose role is SECURITY (LEFT: alert rows preserved;
--    sec_entity_id is NULL for non-security / no-one-present rows).
cte3_security AS (
    SELECT c2.*, em.entity_id AS sec_entity_id, em.entity_name AS sec_name
    FROM cte2_activity c2
    LEFT JOIN entity_metadata em
           ON em.entity_id = c2.present_entity_id
          AND em.entity_healthcare_role = 'SECURITY'
),
-- 4. Confirm that day-present security was actually in the alert's department
--    during the response window (reusing the pushed-down alert timestamps).
cte4_visits AS (
    SELECT c3.*, vis.start_time AS present_at, vis.room_id AS present_room
    FROM cte3_security c3
    LEFT JOIN LATERAL (
        SELECT v.start_time, v.room_id
        FROM entity_visits v
        JOIN room_metadata rmv ON rmv.room_id = v.room_id
             AND rmv.floor_id = c3.floor_id
             AND COALESCE(rmv.department_id, '') = c3.department_id
        WHERE v.entity_id = c3.sec_entity_id
          AND v.start_time >= :'start_ts'::timestamptz
          AND v.start_time <  :'end_ts'::timestamptz
          AND v.start_time BETWEEN c3.t_start AND c3.t_end
          AND v.position_change_type <> 'POSITION_LOST'
        ORDER BY v.start_time
        LIMIT 1
    ) vis ON TRUE
)
-- ---- Final: with/without security presence ---------------------------------
SELECT
    COUNT(DISTINCT uuid)                                                        AS alerts_total,
    COUNT(DISTINCT uuid) FILTER (WHERE sec_entity_id IS NOT NULL)               AS with_security_same_day,
    COUNT(DISTINCT uuid) FILTER (WHERE present_at IS NOT NULL)                  AS with_security_in_window,
    COUNT(DISTINCT uuid)
      - COUNT(DISTINCT uuid) FILTER (WHERE present_at IS NOT NULL)              AS without_security_in_window,
    ROUND(100.0 * (COUNT(DISTINCT uuid)
      - COUNT(DISTINCT uuid) FILTER (WHERE present_at IS NOT NULL))
      / NULLIF(COUNT(DISTINCT uuid), 0), 1)                                     AS pct_without_security
FROM cte4_visits;
