# -*- coding: utf-8 -*-
"""Release gate for schema relationships, procedure plans, and topic coverage."""
import json
import re
from collections import Counter, defaultdict
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def load_js(path):
    text = path.read_text(encoding="utf-8")
    match = re.search(r"=\s*(\{.*\});", text, re.S)
    assert match, "Cannot parse %s" % path
    return json.loads(match.group(1))


schema = load_js(ROOT / "data" / "schema.js")
phases = load_js(ROOT / "data" / "phases.js")
tables = schema["tables"]
rels = schema["rels"]
assets = {asset["id"]: asset for asset in schema["procedures"]}
topics = [topic for phase in phases["phases"] for topic in phase["topics"]]

assert len(tables) == 206
assert sum(table.get("role") != "cohort" for table in tables.values()) == 170
assert sum(table.get("role") == "cohort" for table in tables.values()) == 36
assert len(rels) == 449
assert len(assets) == 31
assert len(topics) == 54

required_rel_fields = {"from", "to", "on", "card", "note", "kind", "evidence", "confidence", "graph"}
for rel in rels:
    assert required_rel_fields <= set(rel), rel
    assert rel["from"] in tables and rel["to"] in tables, rel
    assert rel["kind"] in {"join", "lineage"}, rel
    assert rel["evidence"] in {"curated", "procedure", "pipeline", "schema-fk", "table-family", "key-grain"}, rel
    assert rel["confidence"] in {"high", "medium", "low"}, rel
    assert isinstance(rel["graph"], bool), rel

exact = [(rel["from"], rel["to"], rel["on"], rel["kind"]) for rel in rels]
assert len(exact) == len(set(exact)), "duplicate exact relationships"

source = {name for name, table in tables.items() if table.get("role") != "cohort"}
default_source = [rel for rel in rels if rel["from"] in source and rel["to"] in source and rel["kind"] == "join" and rel["graph"]]
assert len(default_source) == 101, len(default_source)

degree = defaultdict(int)
for rel in rels:
    degree[rel["from"]] += 1
    degree[rel["to"]] += 1
assert not sorted(name for name in source if degree[name] == 0)

evidence = Counter(rel["evidence"] for rel in rels)
assert evidence == Counter({"procedure": 196, "curated": 101, "schema-fk": 63, "key-grain": 42, "pipeline": 35, "table-family": 12})
assert schema["meta"]["relationship_model"]["total"] == len(rels)
assert schema["meta"]["relationship_model"]["by_evidence"] == dict(sorted(evidence.items()))

plans = [topic for topic in topics if topic.get("sp")]
assert len(plans) == 30
assert sum(topic["sp"]["status"] == "implemented" for topic in plans) == 26
assert sum(topic["sp"]["status"] == "blueprint" for topic in plans) == 4
assert {topic["id"] for topic in plans if topic["sp"]["status"] == "blueprint"} == {"appointments", "surgery", "otherreports", "registries"}

for topic in topics:
    if topic["avail"] == "Yes" and topic["tables"]:
        assert topic.get("sp"), "available topic lacks plan: %s" % topic["id"]
    if not topic.get("sp"):
        continue
    plan = topic["sp"]
    primary = "usp_Build_" + plan["name"]
    assert plan["status"] in {"implemented", "blueprint"}
    assert plan["implemented"] == (primary in assets)
    for asset_id in plan["assets"]:
        assert asset_id in assets, (topic["id"], asset_id)

for expected in ("tbl_FCAP1A_ClaimsData", "tbl_FCAP1A_PatientInsurance", "tbl_FCAP1A_FamilyMedicalHistory"):
    assert expected in tables
    assert tables[expected]["role"] == "cohort"

print("PASS: 206 tables, 449 relationships, 31 SQL assets, 30 plans (26 implemented / 4 blueprints)")
