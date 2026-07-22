-- =============================================================================
-- G5 — Security presence at a location-based (duress) alert
-- =============================================================================
-- Answers: "Was a security guard present when this alert fired, and did
--           security respond?" for one alert.
--
-- Usage:  psql "$PG_DSN" -v alert_uuid="'c3ff888e-f5f0-415c-a451-eeee2338d143'" -f query.sql
--         (PG_DSN from curiosity-engine/query-patterns/.env.prod-hca-fork)
--
-- Design notes (see report.md for the full rationale):
--  * SECURITY is identified ONLY via entity_metadata.entity_healthcare_role
--    (fork-only backfill). It spans >1 entity_type_id (615 typed "Security" +
--    310 typed generic "Staff" for company 53afeacbfabb). Filtering by
--    entity_type_id / entity_type_name misses the "Staff"-typed guards entirely.
--  * entity_location_activity is DAILY BINARY presence and its snapshot_time is
--    NOT reliable local-midnight — it clusters in a ~04:00-08:00 UTC early-morning
--    window (drifts with DST, no tz). Use it only as an advisory day-level screen.
--  * The trustworthy source for "present at the alert" is entity_visits
--    (high-frequency position log). We evaluate presence over the alert's
--    RESPONSE WINDOW [triggered_at, resolved_at], not a single instant.
--  * IMPORTANT (TimescaleDB): the entity_visits time bounds must be literal
--    constants for chunk exclusion, otherwise the query scans every chunk and
--    times out. We therefore \gset the alert context into psql variables first
--    and let psql substitute them as literals into the hypertable scan.
-- =============================================================================

\pset pager off

-- ---- 1. Alert context (location + campus tz + local day + response window) --
SELECT
    al.company_id                                                   AS "company_id",
    al.room_id                                                      AS "room_id",
    al.floor_id                                                     AS "floor_id",
    COALESCE(al.department_id, '')                                  AS "department_id",
    rm.campus_timezone                                             AS "tz",
    (COALESCE(al.triggered_at, al.created_at)
        AT TIME ZONE rm.campus_timezone)::date::text                AS "local_day",
    COALESCE(al.triggered_at, al.created_at)::text                  AS "t_start",
    (COALESCE(al.resolved_at, al.closed_at,
              COALESCE(al.triggered_at, al.created_at) + interval '30 min')
        + interval '1 min')::text                                   AS "t_end"
FROM alert al
LEFT JOIN room_metadata rm ON rm.room_id = al.room_id
WHERE al.uuid = :alert_uuid
\gset

-- ---- 2. Verdict: security presence in alert department over the window ------
--        entity_visits time bounds are literals (:'t_start'/:'t_end') so the
--        hypertable is chunk-pruned to the alert's day.
WITH sec AS (
    SELECT entity_id, entity_name
    FROM entity_metadata
    WHERE company_id = :'company_id'
      AND entity_healthcare_role = 'SECURITY'
),
win AS (
    SELECT v.entity_id, s.entity_name, v.start_time,
           (v.room_id = :room_id) AS in_alert_room
    FROM entity_visits v
    JOIN sec s ON s.entity_id = v.entity_id
    JOIN room_metadata rm ON rm.room_id = v.room_id
    WHERE v.start_time BETWEEN :'t_start'::timestamptz AND :'t_end'::timestamptz
      AND rm.floor_id = :floor_id
      AND COALESCE(rm.department_id, '') = :'department_id'
      AND v.position_change_type <> 'POSITION_LOST'
)
SELECT
    :alert_uuid                                                     AS uuid,
    :'local_day'                                                    AS local_day,
    :'tz'                                                           AS campus_timezone,
    :'t_start'::timestamptz                                         AS alert_start,
    COUNT(DISTINCT entity_id)                                       AS security_in_dept,
    COUNT(DISTINCT entity_id) FILTER (WHERE in_alert_room)          AS security_in_alert_room,
    MIN(start_time) FILTER (WHERE in_alert_room)                    AS first_in_room,
    ROUND(EXTRACT(epoch FROM (MIN(start_time) FILTER (WHERE in_alert_room)
                              - :'t_start'::timestamptz)))          AS secs_to_first_in_room,
    STRING_AGG(DISTINCT entity_name, ', ')                          AS responders,
    CASE
        WHEN COUNT(*) FILTER (WHERE in_alert_room) > 0 THEN 'SECURITY_IN_ROOM'
        WHEN COUNT(*) > 0                              THEN 'SECURITY_IN_DEPARTMENT'
        ELSE 'NO_SECURITY_IN_DEPARTMENT'
    END                                                             AS verdict
FROM win;
