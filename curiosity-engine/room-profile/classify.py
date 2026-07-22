import csv
import re
import sys
from collections import Counter

CSV_PATH = "room_metadata.csv"

TYPES = {
    "Clean":        ("65b27d5f3dd3322df812928a", "SUPPLY_STORAGE"),
    "Clinical":     ("65b27d693dd3322df812928b", "PATIENT_AND_EXAM"),
    "Corridor":     ("66fd7b59ebb6533cf163a87f", "TRANSIT"),
    "Exit":         ("65b27d963dd3322df8129290", "TRANSIT"),
    "Non-Clinical": ("65b27d723dd3322df812928c", "STAFF_STATION"),
    "Patient":      ("65b27d7d3dd3322df812928d", "PATIENT_AND_EXAM"),
    "Soiled":       ("65b27d863dd3322df812928e", "SOILED_UTILITY"),
    "Storage":      ("65b27d8e3dd3322df812928f", "SUPPLY_STORAGE"),
}

WORD_RE = re.compile(r"[A-Z0-9']+")


def words(text):
    return WORD_RE.findall(text.upper())


def has_any(wset, terms):
    return any(t in wset for t in terms)


def has_substr(text_upper, terms):
    return any(t in text_upper for t in terms)


DIRECTIONAL_WORDS = {"NORTH", "SOUTH", "EAST", "WEST", "CENTRAL", "CENTER", "N", "S", "E", "W",
                      "FL", "FLOOR"}


def looks_like_bare_room_number(room_name):
    """True for names like '441 (4 SOUTH)' or '635' - a number plus only directional/floor words."""
    w = words((room_name or "").upper())
    if not any(re.search(r"\d", x) for x in w):
        return False
    return all(x in DIRECTIONAL_WORDS or re.search(r"\d", x) for x in w)


# Ordered rule cascade. Each bucket has a set of trigger keywords and the type most
# institutions use for it. Some institutions label a bucket differently (e.g. one hospital
# calls corridors "Exit" while nearly everyone else calls them "Non-Clinical") - that
# per-building convention is learned separately and overrides this default at classify() time.
BUCKETS = [
    ("soiled", {"SOILED", "SOIL"}, "Soiled"),
    ("clean", {"CLEAN"}, "Clean"),
    # Narrowed from a broader egress wordlist: LOBBY/ENTRANCE/STAIR/STAIRWELL/VESTIBULE
    # turned out to be majority-labeled Non-Clinical in this data, so they were dropped -
    # only words that actually flag as "Exit" more often than not are kept.
    ("exit", {"EXIT", "AMBULANCE", "DOCK"}, "Exit"),
    # Ground truth mostly logs corridors as "Non-Clinical", but that carries a
    # STAFF_STATION profile which is a poor fit for a transit space - "Corridor" carries
    # TRANSIT, which matches the room's actual function, so it's used as the default here
    # even though it disagrees with the majority of historical labels.
    ("corridor", {"CORRIDOR", "HALL", "HALLWAY", "PASSAGE"}, "Corridor"),
    ("storage", {"STORAGE", "STOR", "EQUIP", "EQUIPMENT", "SUPPLY"}, "Storage"),
    # Narrowed from a broader clinical-department wordlist: most department-context words
    # (LAB, OR, RADIOLOGY, CATH, SURGERY, CT, MRI, DIALYSIS, etc) turned out to be
    # majority Non-Clinical - those flag the surrounding department, not the room itself.
    ("clinical", {"EXAM", "OPERATING", "WOUND", "EKG", "EEG", "RECOVERY"}, "Clinical"),
    ("patient", {"PATIENT", "PT", "ICU", "PCU", "NEURO", "REHAB", "BED",
                 "POSTPARTUM", "TELE", "LDR", "MEDSURG"}, "Patient"),
    ("nonclinical", {"OFFICE", "LOUNGE", "STAFF", "RESTROOM", "WAITING", "NURSES", "NURSE",
                     "BREAK", "CONFERENCE", "KITCHEN", "ELEVATOR", "ELEV", "MECH",
                     "ELECTRICAL", "TELECOM", "COMM", "ADMIN", "RECEPTION", "STATION",
                     "LOCKER", "LOCKSMITH", "IT", "CLOSET"}, "Non-Clinical"),
]
SUBSTR_EXTRA = {
    "soiled": {"SOILED UTIL"},
    "exit": {"LOADING DOCK"},
    "patient": {"MED SURG", "L&D"},
}
FALLBACK_BUCKET = "fallback_numeric"


def match_bucket(room_name, department_name):
    """Returns the first matching bucket name, or FALLBACK_BUCKET if none match."""
    for source in (room_name or "", department_name or ""):
        u = source.upper()
        w = set(words(u))
        for bucket, terms, _default_type in BUCKETS:
            if has_any(w, terms) or has_substr(u, SUBSTR_EXTRA.get(bucket, ())):
                return bucket
    return FALLBACK_BUCKET


DEFAULT_TYPE_BY_BUCKET = {b: t for b, _terms, t in BUCKETS}


def default_type_for_bucket(bucket, room_name):
    if bucket == FALLBACK_BUCKET:
        # Bare room numbers ("441 (4 SOUTH)") are almost always patient rooms in this
        # data; anything else defaults to the general Non-Clinical bucket.
        return "Patient" if looks_like_bare_room_number(room_name) else "Non-Clinical"
    return DEFAULT_TYPE_BY_BUCKET[bucket]


def classify(room_name, department_name, building_id=None, building_overrides=None):
    """Rule cascade with optional per-building majority-vote override."""
    bucket = match_bucket(room_name, department_name)
    if building_overrides is not None:
        override = building_overrides.get((building_id, bucket))
        if override is not None:
            return override
    return default_type_for_bucket(bucket, room_name)


# Buckets excluded from per-building majority override: historical labels for these are
# known to be taxonomically wrong often enough (e.g. corridors logged as "Non-Clinical" /
# STAFF_STATION when they're transit space) that we'd rather apply the corrected default
# everywhere than reproduce each building's old habit.
NO_OVERRIDE_BUCKETS = {"corridor"}


def build_building_overrides(rows, valid_types, min_examples=3, min_ratio=0.7):
    """Learn per-(building, bucket) majority label where a building's own convention
    disagrees strongly with the global default (e.g. corridors labeled 'Exit' there)."""
    votes = {}
    for row in rows:
        t = row["entity_room_type_name"].strip()
        if t not in valid_types:
            continue
        bucket = match_bucket(row["room_name"], row["department_name"])
        if bucket in NO_OVERRIDE_BUCKETS:
            continue
        key = (row["building_id"], bucket)
        votes.setdefault(key, Counter())[t] += 1

    overrides = {}
    for key, counter in votes.items():
        _building_id, bucket = key
        total = sum(counter.values())
        if total < min_examples:
            continue
        top_type, top_count = counter.most_common(1)[0]
        if top_count / total >= min_ratio and top_type != default_type_for_bucket(bucket, ""):
            overrides[key] = top_type
    return overrides


def main():
    with open(CSV_PATH, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        rows = list(reader)

    overrides = build_building_overrides(rows, set(TYPES))
    print(f"learned {len(overrides)} building-level overrides", file=sys.stderr)
    for (building_id, bucket), t in overrides.items():
        print(f"  building={building_id} bucket={bucket} -> {t}", file=sys.stderr)

    counts = Counter()
    for row in rows:
        t = classify(row["room_name"], row["department_name"], row["building_id"], overrides)
        counts[t] += 1

    for t, c in counts.most_common():
        print(t, c)
    print("total", len(rows))


if __name__ == "__main__":
    main()
