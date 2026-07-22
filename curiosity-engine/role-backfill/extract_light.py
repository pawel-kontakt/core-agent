"""Extract a lighter parquet from hca_entities.parquet with just the columns
needed for staff-role inference: entity_id, status, template_reference.*,
and the 'Staff Role' attribute value."""

import pyarrow as pa
import pyarrow.parquet as pq

SRC = "hca_entities.parquet"
DST = "hca_entities_light.parquet"
COMPANY_ID = "53afeacbfabb"

table = pq.read_table(SRC, columns=["entity_id", "status", "templateReference", "attributes"])
rows = table.to_pylist()

out = {
    "entity_id": [],
    "status": [],
    "template_reference_id": [],
    "template_reference_name": [],
    "template_reference_profile_type": [],
    "staff_role": [],
    "company_id": [],
}

for row in rows:
    tref = row["templateReference"] or {}
    staff_role = None
    for attr in row["attributes"] or []:
        if attr["name"] == "Staff Role":
            staff_role = attr["value"]
            break

    out["entity_id"].append(row["entity_id"])
    out["status"].append(row["status"])
    out["template_reference_id"].append(tref.get("id"))
    out["template_reference_name"].append(tref.get("name"))
    out["template_reference_profile_type"].append(tref.get("profileType"))
    out["staff_role"].append(staff_role)
    out["company_id"].append(COMPANY_ID)

result = pa.table(out)
pq.write_table(result, DST)
print(f"wrote {result.num_rows} rows, {len(result.schema)} columns -> {DST}")
print(result.schema)
