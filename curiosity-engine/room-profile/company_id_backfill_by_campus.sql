-- Backfill room_metadata.company_id by campus, for the HCA tenant.
--
-- Approach: every campus listed in hca_structure.json belongs to company
-- 53afeacbfabb, so set company_id directly for all rooms under those campuses.
--
-- Campus list: 173 campus_ids taken from hca_structure.json.
--   Source had 174 campuses; campus 812929 "Regional Medical Center Of San Jose"
--   is EXCLUDED (flagged "no longer HCA" in the source).
--
-- Default is backfill-safe: only rows where company_id IS NULL are touched, so
-- any already-populated value is left alone. To force-overwrite every room in
-- these campuses regardless of current value, delete the `AND company_id IS NULL`
-- line.

UPDATE room_metadata
SET company_id = '53afeacbfabb'
WHERE company_id IS NULL
  AND campus_id IN (
    1243954, 471367, 456974, 297854, 305314, 421994, 305315, 471355, 1179214,
    1209495, 95154, 465674, 224914, 417054, 963174, 1409474, 1167934, 477154,
    1241614, 477160, 1102614, 471361, 996734, 1282494, 1206474, 484176, 1282414,
    550174, 920135, 417055, 52614, 469035, 349774, 812928, 1166854, 1396374,
    118174, 550175, 477157, 126759, 31316, 1226414, 359234, 484177, 351037,
    199314, 392434, 589758, 590019, 40634, 391136, 87094, 1328874, 471364,
    1409477, 391135, 359236, 224915, 1228155, 484186, 1207194, 45994, 484188,
    1282416, 1207094, 40635, 590016, 1469834, 1409476, 962874, 1075994, 126758,
    471356, 95155, 319814, 471370, 1209494, 471362, 1396375, 589756, 126754,
    205156, 1370654, 1027375, 589755, 812927, 1248915, 581035, 62254, 351034,
    589759, 981354, 92014, 456975, 471363, 1228154, 312194, 1002914, 118177,
    205155, 1209496, 591294, 590021, 1426274, 307394, 471369, 391614, 551795,
    590015, 1328875, 351036, 118175, 590020, 1002915, 1328854, 1295435, 1261015,
    1489774, 1282415, 470794, 899461, 591295, 126755, 1409475, 589760, 1206475,
    1068894, 471358, 267754, 1107214, 428175, 471359, 471372, 471368, 1409494,
    477156, 1076114, 1295434, 126756, 471360, 590017, 1489874, 1282417, 972054,
    484174, 559214, 234335, 551794, 203134, 920136, 339794, 477155, 471373,
    417056, 469034, 1028014, 70074, 484175, 428174, 484187, 1229574, 57494,
    144234, 899457, 178854, 285774, 1440534, 31314, 1328855, 319815, 1476274,
    1155974, 392435
  );

-- ============================================================================
-- Verification
-- ============================================================================
-- Rows still missing company_id within these campuses after the update
-- (should be 0 if every HCA room falls under a listed campus):
--   SELECT campus_id, count(*)
--   FROM room_metadata
--   WHERE company_id IS NULL
--     AND campus_id IN ( /* same list as above */ )
--   GROUP BY campus_id
--   ORDER BY count(*) DESC;
