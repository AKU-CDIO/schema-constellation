#!/usr/bin/env python3
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def load_js(name, variable):
    text = (ROOT / name).read_text(encoding="utf-8")
    match = re.search(rf"window\.{variable}\s*=\s*(\{{.*\}});", text, re.S)
    assert match, f"cannot parse {name}"
    return json.loads(match.group(1))


schema = load_js("data/schema.js", "SCHEMA_DATA")
phases = load_js("data/phases.js", "SCHEMA_PHASES")
source = load_js("data/sp_source.js", "SP_SOURCE")
topics = [topic for phase in phases["phases"] for topic in phase["topics"]]
assert len(topics) == 54
assert source["meta"]["topic_count"] == 54
assert source["meta"]["asset_count"] == 63
assert len(source["assets"]) == 63

threshold = int(schema.get("meta", {}).get("row_count_model", {}).get("near_empty_threshold", 1000))
for topic in topics:
    context = source["topics"].get(topic["id"])
    assert context, f"missing context: {topic['id']}"
    assert context["members"], f"missing topic members: {topic['id']}"
    assert "Topic assembly query" not in context["query"]  # SQL itself, not panel chrome
    assert "SELECT TOP (100)" in context["query"], f"missing assembly SELECT: {topic['id']}"
    assert "relationship gate" in context["query"], f"missing evidence warning: {topic['id']}"
    relations = context["relationships"]
    for member in context["members"]:
        assert any(member in (rel["from"], rel["to"]) for rel in relations), f"disconnected member: {topic['id']} / {member}"
    visible = {
        name for name in context["ids"]
        if schema["tables"][name].get("row_count") is None
        or int(schema["tables"][name]["row_count"]) >= threshold
        or name in {"HimRec_Main", "AdmVisits", "RegAcct_Main"}
    }
    for name in visible:
        assert any(name in (rel["from"], rel["to"]) and rel["from"] in visible and rel["to"] in visible for rel in relations), f"isolated default node: {topic['id']} / {name}"
    for asset_id in topic["sp"]["assets"]:
        asset = source["assets"].get(asset_id)
        assert asset, f"missing SQL asset: {topic['id']} / {asset_id}"
        assert re.search(r"Author\s*:\s*test", asset["sql"], re.I), f"missing author test: {asset_id}"
    primary = source["assets"][topic["sp"]["assets"][0]]["sql"]
    assert re.search(r"(?:CREATE(?:\s+OR\s+ALTER)?|ALTER)\s+(?:PROCEDURE|PROC)\b", primary, re.I), f"missing procedure declaration: {topic['id']}"

explorer = (ROOT / "explorer.html").read_text(encoding="utf-8")
for required in [
    'data/sp_source.js?v=2', 'Topic assembly query', 'Stored procedure',
    'Validation query', 'activeRelationships()', 'edge.association',
]:
    assert required in explorer, required
assert explorer.index('Topic assembly query') < explorer.index('<h3>Stored procedure') < explorer.index('<h3>Validation query')
assert explorer.index('<h3>Stored procedure') < explorer.index('Join evidence -') < explorer.index('<h3>Validation query')
assert 'row.addEventListener("click", () => renderDocTopic(it));' in explorer

home = (ROOT / "index.html").read_text(encoding="utf-8")
assert "Welcome to the" in home and "process-flow" in home
assert "What you can do" not in home and "Under the hood" not in home
mapping = (ROOT / "mapping.html").read_text(encoding="utf-8")
official = "https://home.meditech.com/en/d/clientservicesccimages/otherfiles/2013marchnewsletterdatamapping.pdf"
assert official in mapping
positions = [mapping.index(f"Step {number} -") for number in range(1, 9)]
assert positions == sorted(positions), "mapping steps are not chronological"
print("topic graph/query/SP/Home/Mapping contract: OK")
