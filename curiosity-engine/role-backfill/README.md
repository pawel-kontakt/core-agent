# Healthcare role mapping - upload guide

Three SQL scripts, run in order, populate the healthcare-role lookup and then backfill
`entity_metadata` (the `common-entity-analytics` read model documented in
`kio-apps/services/common-entity-analytics/docs/DOMAIN_OBJECTS.md`):

| File | Rows | Load method | Depends on |
|---|---|---|---|
| `staff_role_dictionary.sql` | 33,181 | batched `INSERT` | - |
| `entity_healthcare_role_map.sql` | 1,125,380 | `COPY ... FROM STDIN` | `staff_role_dictionary.sql` (creates the `healthcare_role` enum type used by both tables) |
| `update_entity_metadata_from_role_map.sql` | updates up to 1,125,380 rows | plain `UPDATE ... FROM` | `entity_healthcare_role_map.sql`, and an `entity_metadata` table reachable from the same connection |

Regenerate the first two from source with `python3 generate_role_mapping_sql.py` (reads
`hca_entities_light.parquet` and `classify_staff_role.py`); the third is static SQL
(no generator - it's a one-off backfill, not derived data).

## Why `entity_healthcare_role_map.sql` needs psql

`COPY ... FROM STDIN` is a libpq protocol feature: the client (psql) reads the data
rows that follow the `COPY` statement in the same file and streams them to the server,
stopping at a line containing only `\.`. This only works through `psql` (or another
client that implements the same COPY handling, e.g. `pgcli`) - it will NOT work
through a plain JDBC/HTTP SQL runner that just forwards raw statement text, since
those don't know to switch into COPY-data mode after the statement.

`staff_role_dictionary.sql` uses plain `INSERT` statements instead, so it runs through
any SQL interface.

## Upload steps

1. **Connect and load the dictionary first** (creates the `healthcare_role` enum type
   the second table's `healthcare_role` column depends on):

   ```bash
   psql "$DATABASE_URL" -f staff_role_dictionary.sql
   ```

   Or, connecting with discrete flags instead of a connection string:

   ```bash
   psql -h <host> -p <port> -U <user> -d <database> -f staff_role_dictionary.sql
   ```

2. **Load the entity mapping** (uses `COPY FROM STDIN`, so it must be psql):

   ```bash
   psql "$DATABASE_URL" -f entity_healthcare_role_map.sql
   ```

   This creates `entity_healthcare_role_map`, streams all 1.1M rows in, then builds
   its indexes - in that order deliberately, since building indexes before the load
   would slow every inserted row down for no benefit.

3. **Verify row counts** match what the generator printed:

   ```sql
   SELECT count(*) FROM staff_role_dictionary;         -- expect 33181
   SELECT count(*) FROM entity_healthcare_role_map;     -- expect 1125380
   ```

4. **Spot-check the join** the two tables are meant to satisfy:

   ```sql
   SELECT healthcare_role, count(*)
   FROM entity_healthcare_role_map
   GROUP BY healthcare_role
   ORDER BY count(*) DESC;
   ```

   Should reproduce the distribution `classify_staff_role.py` printed (RN ~256k,
   PROVIDER ~173k, NON_CLINICAL ~172k, ..., ~350k `NULL`/unmapped).

5. **Backfill `entity_metadata`** once the mapping above is loaded and verified:

   ```bash
   psql "$DATABASE_URL" -f update_entity_metadata_from_role_map.sql
   ```

   Plain `UPDATE ... FROM`, no `COPY` involved, so any SQL interface can run it too.
   It preserves existing `entity_healthcare_role`/`company_id` values (via `COALESCE`)
   for entities the mapping has no classification for, and is safe to re-run.

   **Prerequisite**: `entity_metadata.entity_healthcare_role` is currently backed by
   the Java `StaffRole` enum, which only has 7 values (`EVS, BIOMED, PROVIDER,
   SUPPLY_CHAIN_TECH, MA, RN, TECH`). This script writes all 10 roles, including the
   3 added here (`SECURITY`, `NON_CLINICAL`, `ALLIED_HEALTH`) — `StaffRole` must be
   extended to include them **before** running this, or anything that deserializes
   `entity_healthcare_role` back into `StaffRole` will throw on those rows.

## Re-running / cleanup

Both scripts assume a fresh target - `CREATE TYPE`/`CREATE TABLE` will fail if the
type or tables already exist. To reload from scratch:

```sql
DROP TABLE IF EXISTS entity_healthcare_role_map;
DROP TABLE IF EXISTS staff_role_dictionary;
DROP TYPE IF EXISTS healthcare_role;
```

then repeat steps 1-2.

## If psql isn't an option

If the target's SQL interface genuinely can't run `COPY FROM STDIN` (no psql-like
client available), the fallback is `INSERT`-based population. Ask and it can be
regenerated in that form - it will be a larger file (~77MB vs ~69MB) and slower to
load, but works over any interface that accepts arbitrary SQL text.
