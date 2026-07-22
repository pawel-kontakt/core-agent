# Context

Curiosity engine query agent on kio apss services/common-entity-analytics/docs/DOMAIN_OBJECTS.md db fork

# Issue reported

4. ED security-presence snapshot cadence (G5) Example: "% of ED duress alerts with no security guard present at the time" — presence snapshots (entity_location_activity / entity_location_counts) exist only ~3×/day in an early-morning window that drifts with DST (snapshot_time has no tz), so only ~4–9% of ED duress alerts have a reading near the alert; the population-level answer isn't computable. Ask: 24h snapshot cadence (or continuous presence intervals) + a tz-aware timestamp column, covering both Security entity_type_ids (645 entities, not 95).

## Correct path

entity_location_activity is a per day mark about entity being present (binary yes/no) in specific floor and department. Per day is scoped to timestamp of beginning of day in the local time - if visit happens in the 23:11 UTC in room, room tz is taken from campus, converted to local date and stored as beginning of the day.

Correct resolution for the alert should be:
1. there is an alert, location based, convert date to campus timezone. 
2. take alert location and check if security entity type (via entity_healthcare_role) was present that day on the floor/department
3. no security presence - quick answer - alert without security for the entire day
4. security presence that day - drill down. Take security entity_id located on the flor, fetch details from entity_visits per entity id, correlate specific hours to the alert time. Verify exact room_id match, provide answer about high confident security presence by room, department, floor.

## Goal

Load @curiosity-engine/query-patterns/.env.prod-hca-fork file to get access to live db, verify "Correct path" paragraf solution, use example alert uuid `c3ff888e-f5f0-415c-a451-eeee2338d143` to start building query.
Prepare writen report for the solution.