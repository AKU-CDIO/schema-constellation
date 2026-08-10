# -*- coding: utf-8 -*-
"""Release gate for the complete 54-topic SP quality review."""
import json
import re
from collections import Counter
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def load(path):
    text = path.read_text(encoding="utf-8")
    match = re.search(r"=\s*(\{.*\});", text, re.S)
    assert match, path
    return json.loads(match.group(1))


review = load(ROOT / "data" / "sp_review.js")
schema = load(ROOT / "data" / "schema.js")
topics = review["topics"]
assets = review["assets"]

assert len(topics) == 54
assert len(assets) == 31
assert Counter(item["status"] for item in topics) == Counter({"source-gap": 24, "implemented": 22, "blueprint": 4, "shared": 4})
assert Counter(item["event_based"] for item in topics) == Counter({True: 48, False: 6})
assert {item["id"] for item in topics if item["status"] == "shared"} == {"problemlist", "medorders", "vaccines", "procorders"}
assert {item["id"] for item in topics if item["status"] == "blueprint"} == {"appointments", "surgery", "otherreports", "registries"}

required = {"id", "name", "description", "procedure", "output", "status", "priority", "event_based", "event_model", "grain", "canonical_time", "event_rationale", "planned_sources", "sql_sources", "findings", "recommendations", "query", "query_kind"}
for item in topics:
    assert required <= set(item), item["id"]
    assert item["procedure"].startswith("usp_Build_FCAP1A_")
    assert item["output"].startswith("tbl_FCAP1A_")
    assert item["description"] and item["grain"] and item["canonical_time"] and item["event_rationale"]
    assert "SELECT" in item["query"].upper()
    assert "undefined" not in item["query"].lower()
    if item["status"] in {"implemented", "shared"}:
        assert item["asset"] in assets
    if item["status"] in {"blueprint", "source-gap"}:
        assert item["recommendations"]

summary = review["summary"]
assert summary["topics"] == 54
assert summary["primary_implemented_procedures"] == 22
assert summary["planned_source_gap_topics"] == 15
assert summary["planned_source_gap_references"] == 44
assert summary["drop_publish_primary"] == 22
assert summary["try_catch_primary"] == 21
assert summary["xact_abort_primary"] == 1
assert summary["transaction_primary"] == 1
assert summary["parameterized_primary"] == 1
assert summary["indexed_primary"] == 5
assert len(review["priorities"]) >= 8

asset_ids = {asset["id"] for asset in schema["procedures"]}
assert set(assets) == asset_ids
for asset_id, audit in assets.items():
    assert {"declaration", "parameters", "try_catch", "xact_abort", "transaction", "run_logging", "drop_publish", "index_count", "findings"} <= set(audit), asset_id

print("PASS: 54 topic contracts, 31 audited SQL assets, event/grain/query/gap coverage complete")
