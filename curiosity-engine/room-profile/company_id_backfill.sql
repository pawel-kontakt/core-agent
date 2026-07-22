-- Backfill room_metadata.company_id from the latest entity_visits row per room.
--
-- Strategy:
--   1. Take rooms where company_id IS NULL.
--   2. For each, LATERAL-join the most recent entity_visits row (by start_time DESC)
--      and copy its company_id.
--   3. Process in batches of 1000 rooms.
--
-- Rooms that have no entity_visits at all are naturally skipped (the LATERAL
-- returns no row), so they never block batch progress and stay NULL.
--
-- NOTE (performance): entity_visits is a TimescaleDB hypertable with indexes only
-- on entity_id / (entity_id, start_time DESC) -- there is NO index on room_id.
-- The per-room latest-visit lookup therefore scans chunks by room_id. For a large
-- backfill consider first creating a helper index:
--     CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_entity_visits_room_start
--         ON entity_visits (room_id, start_time DESC);
-- (drop it afterwards if it is not needed for regular query load).

-- ============================================================================
-- OPTION A -- auto-batching loop (PL/pgSQL). Run once; it iterates until done.
-- Requires transaction control support (PostgreSQL 11+) and must NOT be wrapped
-- in an explicit BEGIN/COMMIT block (run it standalone in psql).
-- ============================================================================
DO $$
DECLARE
    batch_size CONSTANT integer := 1000;
    updated    integer;
    total      bigint := 0;
BEGIN
    LOOP
        UPDATE room_metadata rm
        SET company_id = v.company_id
        FROM (
            SELECT r.room_id, lv.company_id
            FROM room_metadata r
            CROSS JOIN LATERAL (
                SELECT ev.company_id
                FROM entity_visits ev
                WHERE ev.room_id = r.room_id
                  AND ev.start_time >= now() - interval '30 days'
                ORDER BY ev.start_time DESC
                LIMIT 1
            ) lv
            WHERE r.company_id IS NULL
            LIMIT batch_size
        ) v
        WHERE rm.room_id = v.room_id;

        GET DIAGNOSTICS updated = ROW_COUNT;
        total := total + updated;
        RAISE NOTICE 'batch updated % rooms (running total %)', updated, total;

        EXIT WHEN updated = 0;
        COMMIT;   -- commit each batch so progress survives and locks are released
    END LOOP;

    RAISE NOTICE 'done: % rooms backfilled', total;
END $$;

-- ============================================================================
-- OPTION B -- single batch statement (run repeatedly until it reports 0 rows).
-- Use this if you prefer manual control or your client disallows DO/COMMIT.
-- The LIMIT is applied AFTER the LATERAL join, so only rooms that actually have
-- a visit count toward the 1000 -- visit-less rooms never stall the loop.
-- ============================================================================
UPDATE room_metadata rm
SET company_id = v.company_id
FROM (
    SELECT r.room_id, lv.company_id
    FROM room_metadata r
    CROSS JOIN LATERAL (
        SELECT ev.company_id
        FROM entity_visits ev
        WHERE ev.room_id = r.room_id
          AND ev.start_time >= now() - interval '30 days'
        ORDER BY ev.start_time DESC
        LIMIT 1
    ) lv
    WHERE r.company_id IS NULL
    LIMIT 1000
) v
WHERE rm.room_id = v.room_id;

-- ============================================================================
-- Verification helpers
-- ============================================================================
-- Rooms still missing company_id (broken down by whether any visit exists):
--   SELECT
--       count(*) FILTER (WHERE has_visit)     AS null_but_has_visits,
--       count(*) FILTER (WHERE NOT has_visit) AS null_no_visits
--   FROM (
--       SELECT r.room_id,
--              EXISTS (
--                  SELECT 1 FROM entity_visits ev
--                  WHERE ev.room_id = r.room_id
--                    AND ev.start_time >= now() - interval '30 days'
--              ) AS has_visit
--       FROM room_metadata r
--       WHERE r.company_id IS NULL
--   ) s;
