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
assert len(assets) == 63
assert Counter(item["status"] for item in topics) == Counter({"implemented": 54})
assert Counter(item["event_based"] for item in topics) == Counter({True: 48, False: 6})
assert not {item["id"] for item in topics if item["status"] == "shared"}
assert not {item["id"] for item in topics if item["status"] == "blueprint"}

required = {"id", "name", "description", "procedure", "output", "status", "priority", "event_based", "event_model", "grain", "canonical_time", "event_rationale", "planned_sources", "sql_sources", "findings", "recommendations", "suggestions", "review_checks", "improved_sp", "query", "query_kind", "author", "evidence_tier"}
for item in topics:
    assert required <= set(item), item["id"]
    assert item["procedure"].startswith("usp_Build_FCAP1A_")
    assert item["output"].startswith("tbl_FCAP1A_")
    assert item["description"] and item["grain"] and item["canonical_time"] and item["event_rationale"]
    assert "SELECT" in item["query"].upper()
    assert "undefined" not in item["query"].lower()
    assert item["improved_sp"], item["id"]
    for suggestion in item["suggestions"]:
        assert suggestion["check"] in {1, 2, 3, 4, 6}, (item["id"], suggestion)
        assert suggestion["note"], (item["id"], suggestion)
    assert len(item["review_checks"]) == 6, item["id"]
    assert {check["check"] for check in item["review_checks"]} == {1, 2, 3, 4, 5, 6}, item["id"]
    assert all(check["label"] for check in item["review_checks"]), item["id"]
    assert all(check["note"] for check in item["review_checks"]), item["id"]
    if item["status"] in {"implemented", "shared"}:
        assert item["asset"] in assets
        assert "Reconcile planned-vs-SQL source coverage before accepting the procedure as complete." in item["recommendations"], item["id"]
        assert "Build into a staging table and publish with a short transactional swap." in item["recommendations"], item["id"]
        assert "Add window/watermark parameters and an incremental execution path." in item["recommendations"], item["id"]
        assert "Define output indexes for patient, visit, event time, and the natural record key." in item["recommendations"], item["id"]
    if item["status"] in {"blueprint", "source-gap"}:
        assert item["recommendations"]

summary = review["summary"]
assert summary["topics"] == 54
assert summary["primary_implemented_procedures"] == 54
assert summary["planned_source_gap_topics"] == 12
assert summary["planned_source_gap_references"] == 33
assert summary["alter_only_primary"] == 20
assert summary["drop_publish_primary"] == 23
assert summary["try_catch_primary"] == 53
assert summary["xact_abort_primary"] == 33
assert summary["transaction_primary"] == 32
assert summary["parameterized_primary"] == 32
assert summary["indexed_primary"] == 36
assert summary["topics_with_suggestions"] == 45
assert summary["suggestion_count"] == 65
assert len(review["priorities"]) >= 8

asset_ids = {asset["id"] for asset in schema["procedures"]}
assert set(assets) == asset_ids
for asset_id, audit in assets.items():
    assert {"declaration", "parameters", "try_catch", "xact_abort", "transaction", "run_logging", "drop_publish", "index_count", "findings"} <= set(audit), asset_id

print("PASS: 54 implemented topic contracts, 63 audited SQL assets, event/grain/query/evidence coverage complete")
