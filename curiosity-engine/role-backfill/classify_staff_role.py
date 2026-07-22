"""Classify distinct `staff_role` free-text values (PERSON entities only) against
the EntityHealthcareStaffRole enum, extended with three proposed roles:
SECURITY, NON_CLINICAL, ALLIED_HEALTH (independently-licensed clinical professions
that aren't physicians/APPs/nurses: pharmacist, social worker, dietitian, PT/OT/SLP).

Keyword cascade, most specific bucket first. Values that don't match any rule are
left UNMAPPED for manual review - this is real hospital HR job-title data with a
long tail of one-off/free-text entries that no keyword list will fully cover.
"""

import csv
import re
from collections import Counter

import pyarrow.parquet as pq
import pyarrow.compute as pc

SRC = "hca_entities_light.parquet"
OUT_CSV = "staff_role_classification.csv"

WORD_RE = re.compile(r"[A-Z0-9']+")


def words(text):
    return set(WORD_RE.findall(text.upper()))


# Short/generic abbreviations that must match a whole token (substring matching would
# false-positive: "RN" inside "OVERNIGHT", "MA" inside "MATERNAL", "MD" inside "MDS", ...).
WORD_TERMS = {"EVS", "SPD", "RN", "LVN", "LPN", "MA", "CMA", "MD", "DO", "PA", "NP",
              "CRNA", "TECH", "EMT", "RRT", "CNA", "PTA", "OTA"}

# (bucket_name, target_role, trigger terms). Terms in WORD_TERMS are matched as whole
# tokens; everything else is matched as a substring (safe because these are long/
# distinctive enough not to collide with unrelated words).
CASCADE = [
    ("evs", "EVS", {"EVS", "ENVIRONMENTAL SERVICES", "HOUSEKEEP"}),
    ("biomed", "BIOMED", {"BIOMED", "BIO-MED", "CLINICAL ENGINEER"}),
    ("supply_chain", "SUPPLY_CHAIN_TECH",
     {"SUPPLY CHAIN", "MATERIALS MANAGEMENT", "MATERIAL HANDLER", "MAT HANDLER",
      "LOGISTICS", "SPD", "STERILE PROCESSING", "CENTRAL SUPPLY"}),
    # "INFORMATION SECURITY" is an IT/cyber role, not a facility security guard - must
    # be excluded before the general "SECURITY" substring below claims it.
    ("it_security", "NON_CLINICAL", {"INFORMATION SECURITY"}),
    ("security", "SECURITY",
     {"SECURITY", "POLICE OFFICER", "LAW ENFORCEMENT", "SHERIFF"}),
    # Advanced-practice providers mention "NURSE"/"PHYSICIAN ASSISTANT" but are PROVIDER,
    # so this must run before the general nursing bucket.
    ("app_provider", "PROVIDER",
     {"NURSE PRACTITIONER", "PHYSICIAN ASSISTANT", "NURSE ANESTHETIST", "CRNA", "APP -",
      "APP-", "NP)", "PA)"}),
    ("rn", "RN",
     {"REGISTERED NURSE", "RN", "NURSE", "NURSING", "LVN", "LPN"}),
    ("ma", "MA",
     {"MEDICAL ASSISTANT", "MEDICAL ASST", "MED ASST", "MED ASSISTANT", "CMA"}),
    # "STUDENT" runs before the profession-specific buckets below so trainees (Pharmacy
    # Student, PA Student, Medical Student, ...) land in NON_CLINICAL instead of being
    # misread as the professional itself. Nurse/RN students are already resolved above
    # via the "NURSE" keyword and are left alone.
    ("student", "NON_CLINICAL", {"STUDENT"}),
    # "PHARMACY" alone is deliberately excluded - it would also catch "Pharmacy
    # Technician", which is a technician tier and belongs in TECH, not here.
    ("allied_health", "ALLIED_HEALTH",
     {"PHARMACIST", "SOCIAL WORK", "DIETITIAN", "SPEECH LANGUAGE",
      "SPEECH-LANGUAGE", "PHYSICAL THERAPIST", "OCCUPATIONAL THERAPIST"}),
    ("provider", "PROVIDER",
     {"PHYSICIAN", "HOSPITALIST", "SURGEON", "SURGERY", "ANESTHESI", "CARDIOLOGY",
      "NEUROLOGY", "NEPHROLOGY", "GASTROENTEROLOGY", "ONCOLOGY", "PEDIATRICS",
      "OBSTETRICS", "GYNECOLOGY", "RADIOLOGY", "PSYCHIATRY", "DERMATOLOGY", "UROLOGY",
      "OPHTHALMOLOGY", "OTOLARYNGOLOGY", "FAMILY MEDICINE", "INTERNAL MEDICINE",
      "EMERGENCY MEDICINE", "PULMONOLOGY", "RHEUMATOLOGY", "ENDOCRINOLOGY",
      "PATHOLOGY", "ATTENDING", "MEDICAL DIRECTOR", "PODIATRY",
      "PHYSIATRY", "ORTHOPAEDIC", "ORTHOPEDIC", "RESIDENT", "BEHAVIORAL HEALTH",
      "CRITICAL CARE", "NEONATAL", "PERINATAL", "PULMONARY", "INFECTIOUS DISEASE",
      "PHYSICAL MEDICINE", "HEMATOLOGY", "ALLERGY", "IMMUNOLOGY", "HOSPICE",
      "PALLIATIVE", "DENTISTRY", "MATERNAL", "FETAL MEDICINE", "TRAUMA", "PAIN MEDICINE"}),
    ("tech", "TECH",
     {"TECH", "TECHNICIAN", "TECHNOLOGIST", "PARAMEDIC", "EMT", "PHLEBOTOM",
      "RESPIRATORY", "SONOGRAPHER", "PERFUSION", "RRT", "CNA", "PTA", "OTA", "SITTER",
      "PATIENT SAFETY ATTENDANT", "LABORATORY ASST", "LAB ASST", "SCRIBE",
      "PHYSICAL THERAPY", "OCCUPATIONAL THERAPY"}),
    ("non_clinical", "NON_CLINICAL",
     {"OFFICE", "CLERK", "SECRETARY", "REGISTRAR", "SCHEDULER", "ADMIN", "RECEPTION",
      "CODER", "ABSTRACTOR", "HIM SPEC", "BILLING", "COLLECTOR", "COLLECTION",
      "CUSTOMER", "PATIENT REP", "PBX", "TRANSPORTER", "FOOD", "NUTRITION", "DIETARY",
      "COOK", "FACULTY", "VOLUNTEER", "VENDOR", "CONTRACTOR", "INTERN", "CONSULTANT",
      "ANALYST", "GHR EMAIL", "OPO STAFF", "TEAM MEMBER", "CROSS COVERAGE"}),
]

# High-volume ambiguous strings that shouldn't be pattern-matched blindly - decided
# explicitly instead of via keyword. These denote EHR/badge access tiers or truly
# indeterminate placeholders rather than an actual job function - no role fits them.
EXPLICIT = {
    "1NON-PRIVILEGED PROVIDER": None,
    "1UNDEFINED PROVIDER (NO SYSTEM ACCESS)": None,
    "NON-PRIVILEGED PROVIDER": None,
    "": None,
    "OTHER": None,
    "STAFF": None,
    # Contain "PHYSICIAN" but are clerical/office staff, not the physician - must be
    # pinned here since the "provider" bucket would otherwise claim them via that word.
    "PHYSICIAN OFFICE STAFF": "NON_CLINICAL",
    "PHYSICIAN OFFICE STAFF CLINICAL": "NON_CLINICAL",
    "TNA PHYSICIAN OFFICE STAFF": "NON_CLINICAL",
}


def classify(value):
    if value is None:
        return None
    upper = value.upper().strip()
    if upper in EXPLICIT:
        return EXPLICIT[upper]
    w = words(upper)
    for _bucket, role, terms in CASCADE:
        word_terms = terms & WORD_TERMS
        substr_terms = terms - WORD_TERMS
        if any(t in w for t in word_terms) or any(t in upper for t in substr_terms):
            return role
    return None


def main():
    t = pq.read_table(SRC)
    mask = pc.equal(t.column("template_reference_profile_type"), "PERSON")
    sub = t.filter(mask)
    vals = sub.column("staff_role").to_pylist()
    counts = Counter(v for v in vals if v is not None)

    rows = []
    role_totals = Counter()
    unmapped_volume = 0
    for value, n in counts.items():
        role = classify(value)
        role_totals[role or "UNMAPPED"] += n
        if role is None:
            unmapped_volume += n
        rows.append((value, n, role or "UNMAPPED"))

    rows.sort(key=lambda r: -r[1])

    with open(OUT_CSV, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(["staff_role", "count", "classified_role"])
        writer.writerows(rows)

    total = sum(counts.values())
    print(f"distinct staff_role values (PERSON): {len(counts)}")
    print(f"total rows classified: {total}")
    print()
    for role, n in role_totals.most_common():
        print(f"{role:20s} {n:8d}  ({n/total*100:5.1f}%)")
    print()
    print(f"unmapped volume: {unmapped_volume} ({unmapped_volume/total*100:.1f}%)")
    print(f"wrote {OUT_CSV}")


if __name__ == "__main__":
    main()
