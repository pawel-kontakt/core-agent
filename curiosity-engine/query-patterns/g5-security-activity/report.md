# G5 — Security presence at duress alerts: verification report

**Scope:** Verify the "Correct path" for answering *"was a security guard present when a
location-based duress alert fired?"* against the live curiosity-engine fork DB
(`cea_prod_0` @ prod-hca-fork), using example alert
`c3ff888e-f5f0-415c-a451-eeee2338d143`.

**Verdict on the path:** Directionally correct. One confirmation (§2.1, role-not-type), two
corrections to the path (§2.3 day-level presence over-attributes, §2.4 use the response window
not an instant), and one data-semantics clarification (§2.2, the snapshot cadence is fine — the
timestamp is just confusing). All queries were run read-only as `curiosity_engine_cea_ro`.

> **Correction (post-review of the aggregation job).** An earlier draft of this report
> claimed the `entity_location_activity` snapshot cadence was "broken / early-morning-only."
> That was a **misdiagnosis** — see §2.2. The job buckets correctly to campus-local day; the
> confusion is a naive-`timestamp` column holding a UTC instant of *local midnight*. The
> deliverable query (`query.sql`) is unaffected — it never reads that table.

---

## 1. The example alert

| Field | Value |
|---|---|
| uuid | `c3ff888e-f5f0-415c-a451-eeee2338d143` |
| type / condition | `BUTTON_CLICK` / `ANY_BUTTON_CLICK` (STAFF_SAFE duress) |
| urgency | `CRITICAL` |
| company_id | `53afeacbfabb` |
| campus | Methodist Hospital (`1328855`), tz **America/Chicago** |
| floor / dept | `1351614` (2nd) / `3fd5f9f4…` (MHMH – 2nd South Tower, SICU) |
| room | `1361125` — *South Tower SICU PATIENT RM 4* |
| trigger entity | Lauren Cheverton (`6810675a…`), **type "Staff"** |
| triggered_at | `2026-07-09 05:40:31.809+00` → **2026-07-09 00:40 local (CDT)** |
| resolved_at | `2026-07-09 06:09:16.341+00` (`HANDLED_BY_SECURITY`, by USER *Miranda Moore*) |

Local day = **2026-07-09**. Note the alert is only 40 min past local midnight.

---

## 2. What we verified

### 2.1 SECURITY must be identified by `entity_healthcare_role`, not by type — CONFIRMED

For company `53afeacbfabb`, `entity_healthcare_role = 'SECURITY'` covers **925 entities across
two `entity_type_id`s**:

| entity_type_id | entity_type_name | entities |
|---|---|---|
| `652e3a42fbfb092a15a4808e` | **Security** | 615 |
| `664e6e8ab8fe1b2b766ee648` | **Staff** (generic) | 310 |

The 310 guards typed as generic **"Staff"** are invisible to any `entity_type_id` /
`entity_type_name` filter. In this very alert, **every security officer who responded is typed
"Staff"** — a type-based query would have concluded "no security responded," which is wrong.
This validates the pattern's core ask (cover *both* security type ids) and shows the role
column is the only correct discriminator.

*(The pattern quoted "645 vs 95"; live counts are 925 across 2 type ids. The exact numbers have
drifted but the structural point — role beats type, and one of the type ids is generic "Staff" —
holds and is in fact stronger than stated.)*

### 2.2 `entity_location_activity` cadence — CORRECT daily bucket, but a confusing timestamp (revised)

The reported issue framed the presence snapshots as existing "only ~3×/day in an early-morning
window." **That premise is a misdiagnosis.** Reading `aggregate_daily_entity_location_activity`:

```sql
time_bucket('1 day', eph.snapshot_time, campus_timezone) AS snapshot_time
```

- The job buckets each `entity_position_hourly` row into the **campus-local day** and stores the
  **instant of local midnight**. It processes one completed local day and `GROUP BY`s over the
  whole 24 h → **exactly one row per entity per floor/dept per local day** (true daily binary
  presence, as documented).
- `snapshot_time` is `timestamp without time zone`; the local-midnight *instant* is stored as its
  **UTC wall-clock**. For America/Chicago that is `05:00:00` in summer (CDT, UTC−5) and would be
  `06:00:00` in winter (CST, UTC−6) — the real "DST drift."

Verified: one Chicago floor has a single distinct `snapshot_time` per day, all `05:00:00`. The
"04:00–08:00 UTC cluster" I first saw across *all* floors is simply the **local midnights of the
different US timezones** (Eastern/Central/Mountain/Pacific + DST), not multiple daily samples.

**Two real, narrower takeaways survive:**
1. **Join footgun.** You must match on the local-midnight-in-UTC value, not naive local midnight.
   Correct key:
   ```sql
   el.snapshot_time = ((date_trunc('day', a.triggered_at AT TIME ZONE tz))
                        AT TIME ZONE tz) AT TIME ZONE 'UTC'
   ```
   (Joining on `(local_date)::timestamp` = `00:00:00` returns **zero rows** — my original error.)
2. **Wrong grain for the KPI.** This table answers *"was security on this floor/dept **that
   day**?"* — a whole-day binary. It can never sit "near the alert time"; it is a midnight marker.
   The reported "only 4–9 % of alerts have a nearby reading" comes from looking for a snapshot near
   the alert *timestamp*, which this table is not designed to provide. A **day-level** population
   answer is perfectly computable from it; an **at-the-alert-time** answer is not — that requires
   `entity_visits` (or continuous presence intervals).

### 2.3 Day-level presence is BINARY and massively over-attributes — NEW / IMPORTANT

Step 2 of the path ("was security present that day on the floor/department") using
`entity_location_activity` reported **9 security in the alert's department that day**. But
`entity_location_activity` is *one binary row per entity per floor/dept per day* — a momentary
pass-through counts. Drilling into `entity_visits` for their position **as of the alert instant**:

| match at 05:40:31 (all 925 security) | count |
|---|---|
| in alert **room** | **0** |
| in alert **department** | **0** |
| same **floor** (other wing) | 1 (fix 2.7 min old) |
| elsewhere (live fix) | 347 |
| position-lost / stale (some ~466 days) | 561 |

So the day-level "security in department = yes" is a **false positive** at the alert instant, and
the raw roster is noisy (561 of 925 badges have no live fix — not actively tracked). The day
screen is at best a cheap advisory filter, never the answer.

### 2.4 The right question is the RESPONSE WINDOW, not an instant — DECISIVE

A single-instant fix is both sparse and noisy (we observed a system-wide batch reposition at
05:40:2x that transiently mislocated the SICU team into ER/Children's Tower). Evaluating
`entity_visits` over the alert's active window **[triggered_at → resolved_at]**, filtered to the
alert department and tagged for the alert room, gives the true picture:

- **Dominic Fontanez** enters alert room `1361125` at **05:42:52** — **141 s after the press**
- Brandon Parker (05:43:06), Daniel Barrera (05:43:42) follow; Christopher Thomas enters at 06:09:08
- 5 distinct security officers in-department, **4 of them inside the alert room**, continuously
  present in the SICU room/corridor/nurse-station until resolution at 06:09.

**True answer for this alert: security was NOT co-located at the instant of the press, but a
security team was on-scene inside the alert room within ~2m20s and stayed through resolution** —
fully consistent with `resolution_code = HANDLED_BY_SECURITY`.

Bonus insight: RTLS shows security on-scene in ~2 min, whereas the app `acknowledged_at` /
`resolved_at` timestamps (both by user Miranda Moore) only stamp at 06:09 — 29 min later. **RTLS
presence is a truer response signal than the manual ack/resolve timestamps.**

---

## 3. Corrected "Correct path"

1. **Alert → local day.** Join `alert.room_id → room_metadata` for `campus_timezone`; compute
   `local_day = (triggered_at AT TIME ZONE tz)::date`. Keep the raw `triggered_at`/`resolved_at`
   for the window.
2. **Security roster.** `entity_metadata WHERE company_id = <alert company> AND
   entity_healthcare_role = 'SECURITY'`. **Never** filter by `entity_type_id`/name.
3. **(Optional) day screen.** `entity_location_activity` for `floor_id` + `local_day` gives a
   cheap *"was security on this floor at all that day"* hint — but it is **whole-day binary**, so
   do **not** treat "present that day" as the answer and do **not** let it gate the drill-down (it
   over-attributes badly — see §2.3). Match `snapshot_time` on local-midnight-in-UTC, not naive
   local midnight (§2.2 footgun).
4. **Response-window presence (the answer).** Scan `entity_visits` for the security roster over
   `[triggered_at, resolved_at]`, join `room_metadata`, keep rows on the alert `floor_id` +
   `department_id`, exclude `POSITION_LOST`, and tag `room_id = alert.room_id`. Classify:
   `SECURITY_IN_ROOM` > `SECURITY_IN_DEPARTMENT` > `NO_SECURITY_IN_DEPARTMENT`, and report
   time-to-first-in-room.

### Performance caveat (TimescaleDB)
`entity_visits` is a hypertable partitioned by `start_time`. The window bounds **must be literal
constants** for chunk exclusion; passing them through a CTE makes the planner scan every chunk and
the query times out. `query.sql` captures the alert context with `\gset` and substitutes the
bounds as literals.

---

## 4. Deliverable query

[`query.sql`](query.sql) — parameterised by `alert_uuid`, returns one verdict row.

```bash
set -a; source ../.env.prod-hca-fork; set +a; export PGSSLMODE=require
psql "$PG_DSN" -x -v alert_uuid="'c3ff888e-f5f0-415c-a451-eeee2338d143'" -f query.sql
```

Verified output for the example alert:

| field | value |
|---|---|
| verdict | **SECURITY_IN_ROOM** |
| security_in_dept | 5 |
| security_in_alert_room | 4 |
| secs_to_first_in_room | **141** |
| responders | Brandon Parker, Christopher Thomas, Daniel Barrera, Dominic Fontanez, Pedro Morin |

---

## 4b. Batch variant — population "alerts without security presence"

[`query_batch.sql`](query_batch.sql) — same presence logic applied across a time window and a set
of campuses. It lists every location-based duress (`BUTTON_CLICK`) alert with **no security anywhere
in its department** during `[triggered_at, resolved_at]`, plus per-campus rates. It stages
security visits into indexed temp tables (window bounds as literals for chunk pruning) so the
per-alert check is an index probe, not a 6 M-row range join. Runtime ≈ 4–8 min (dominated by the
~6.2 M-row `entity_visits` materialisation).

**Run for 2026-02-01 → 2026-03-03, campuses 996734 / 1295435 / 205156 / 1228155 / 95155:**
711 duress alerts, **360 (50.6 %) with no security in department**.

| campus | duress alerts | without security | % | security entities tracked in window |
|---|---:|---:|---:|---:|
| Corpus Christi | 125 | 122 | **97.6** | **1** |
| Sunrise | 209 | 183 | **87.6** | 68 (9 floors) |
| Florida Osceola | 125 | 37 | 29.6 | 33 (5 floors) |
| Florida Aventura | 128 | 10 | 7.8 | 19 (10 floors) |
| Memorial Savannah | 124 | 8 | 6.5 | 39 (17 floors) |

> **Read this as coverage, not behaviour.** The 6.5 %→97.6 % spread tracks **security-badge RTLS
> coverage**, not real response. Corpus Christi has **one** tracked security entity all month, so
> its 97.6 % is a data gap. The smoking gun: of the 360 flagged alerts, **141 are `TEST`** and
> **115 are `HANDLED_BY_SECURITY`** — security *demonstrably* handled them, yet no security shows in
> the department's RTLS (untracked responders). Only the **50 `HANDLED_BEFORE_SECURITY_ARRIVED`**
> are unambiguous true-positives. For a usable KPI: exclude test/accidental/duplicate resolutions,
> and **gate on per-floor security tracking coverage** (only score alerts on floors/depts where
> security is actually badged) — otherwise the metric just measures where badges are worn.

---

## 5. Recommendations (data platform)

To make the population-level KPI ("% of ED duress alerts with no security present") actually
computable — beyond the per-alert `entity_visits` drill-down, which is correct but heavy:

1. **Add an at-the-time presence signal (the cadence isn't the problem — the grain is).**
   `entity_location_activity` is already a correct once-per-local-day aggregate; it simply can't
   answer "present *at the alert*." To make the KPI cheap without per-alert `entity_visits` scans,
   materialise **continuous presence intervals** (entity × room × [enter, exit]) from
   `entity_visits`, ideally carrying `entity_healthcare_role`. Do **not** just add more daily
   snapshots — that doesn't fix the grain mismatch.
2. **Make the timestamp tz-aware / unambiguous.** `entity_location_activity.snapshot_time` /
   `entity_location_counts.snapshot_time` are naive `timestamp` that actually hold the *UTC instant
   of local midnight*, so they drift with DST and invite the wrong-key join in §2.2. Store
   `timestamptz`, or an explicit `campus_timezone` + `local_date` pair, so joins are unambiguous.
3. **Key presence by role, and cover both security type ids.** Ensure the aggregation carries
   `entity_healthcare_role` (or an is_security flag) so security is counted across *both*
   `652e3a42…` ("Security") and `664e6e8a…` (generic "Staff") — 925 entities, not the 615 the
   "Security" type alone would yield.
4. **Adopt a response-window definition** of "security present at an alert" (presence within
   `[triggered_at, resolved_at]`, or a fixed SLA window), not an instantaneous snapshot — the
   instant is sparse and noisy, the window is what operations actually cares about.
