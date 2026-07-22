-- Backfill entity_metadata.entity_healthcare_role and entity_metadata.company_id
-- from entity_healthcare_role_map (see entity_healthcare_role_map.sql /
-- staff_role_dictionary.sql for how that mapping was derived and uploaded).
--
-- entity_metadata.entity_healthcare_role stays TEXT (per kio-apps
-- services/common-entity-analytics/docs/DOMAIN_OBJECTS.md - "text (enum)"), NOT the
-- Postgres `healthcare_role` enum type used by the mapping/dictionary tables, so the
-- value is cast to text on write.
--
-- PREREQUISITE: entity_metadata.entity_healthcare_role is backed today by the Java
-- `StaffRole` enum (EVS, BIOMED, PROVIDER, SUPPLY_CHAIN_TECH, MA, RN, TECH). This
-- update also writes the 3 roles added in the curiosity-engine dictionary
-- (SECURITY, NON_CLINICAL, ALLIED_HEALTH) - `StaffRole` must be extended to include
-- them before this runs, or anything that deserializes this column back into
-- StaffRole (e.g. `StaffRole.valueOf(...)`) will throw on those rows.
--
-- Existing values are preserved (COALESCE) rather than null-wiped when the mapping
-- has no classification for an entity (~31.6% of PERSON entities - see
-- staff_role_classification.csv), matching the null-safe upsert convention already
-- used elsewhere in this schema (see the `alert` table's COALESCE(EXCLUDED, existing)
-- pattern in DOMAIN_OBJECTS.md). Safe to re-run.

UPDATE entity_metadata em
SET
    entity_healthcare_role = COALESCE(m.healthcare_role::text, em.entity_healthcare_role),
    company_id = COALESCE(m.company_id, em.company_id)
FROM entity_healthcare_role_map m
WHERE em.entity_id = m.entity_id;
