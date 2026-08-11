# -*- coding: utf-8 -*-
"""Production-readiness contract for the static schema platform."""
from __future__ import annotations

import json
import re
from html.parser import HTMLParser
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HTML_PAGES = [
    "index.html", "explorer.html", "topics.html", "sql.html",
    "mapping.html", "sps.html", "sp-review.html", "404.html",
]
NAV_TARGETS = {
    "index.html", "explorer.html", "topics.html", "sql.html",
    "mapping.html", "sps.html", "sp-review.html",
}


def load_window(path: Path, name: str):
    text = path.read_text(encoding="utf-8")
    match = re.search(rf"window\.{name}\s*=\s*(\{{.*\}});", text, re.S)
    assert match, f"cannot parse {path.name}"
    return json.loads(match.group(1))


class AssetParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.assets = []
        self.links = []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "script" and attrs.get("src"):
            self.assets.append(attrs["src"])
        if tag == "link" and attrs.get("href"):
            self.assets.append(attrs["href"])
        if tag == "a" and attrs.get("href"):
            self.links.append(attrs["href"])


def local_target(value: str):
    clean = value.split("?", 1)[0].split("#", 1)[0]
    if not clean or "://" in clean or clean.startswith("/"):
        return None
    return clean


def main():
    schema = load_window(ROOT / "data" / "schema.js", "SCHEMA_DATA")
    phases = load_window(ROOT / "data" / "phases.js", "SCHEMA_PHASES")
    review = load_window(ROOT / "data" / "sp_review.js", "SP_REVIEW")
    tables = schema["tables"]
    topic_ids = {item["id"] for item in schema["topics"]}
    assert len(tables) == 261
    assert len(schema["rels"]) == 645
    assert all(t.get("topic") in topic_ids for t in tables.values())
    assert all(t.get("role") in {"hub", "entity", "dict", "cohort"} for t in tables.values())
    assert all(t.get("zone") in schema["zones"] for t in tables.values())
    assert all(t.get("desc") and not t["desc"].startswith("Audited Meditech source") for t in tables.values())

    topics = [topic for phase in phases["phases"] for topic in phase["topics"]]
    assert len(phases["phases"]) == 5
    assert len(topics) == 54
    assert len({topic["id"] for topic in topics}) == 54
    assert all(topic["cat"] in topic_ids for topic in topics)
    assert all(name in tables for topic in topics for name in topic["tables"])
    assert all(topic.get("sp", {}).get("implemented") for topic in topics)
    assets = {asset["id"] for asset in schema["procedures"]}
    assert len(assets) == 63
    assert all(asset in assets for topic in topics for asset in topic["sp"]["assets"])
    assert review["summary"]["status"]["implemented"] == 54
    assert len(review["topics"]) == 54

    row_model = json.loads((ROOT / "dev" / "source_row_counts.json").read_text(encoding="utf-8"))
    qualities = {}
    for item in row_model["tables"].values():
        quality = item["quality"]
        qualities[quality] = qualities.get(quality, 0) + 1
    assert len(row_model["tables"]) == 17095
    assert "SysDrTables" not in row_model["tables"]
    assert "SysDrColumns" not in row_model["tables"]
    assert qualities == {"unknown": 1, "usable": 3150, "near-empty": 4734, "empty": 9210}

    for page_name in HTML_PAGES:
        page = ROOT / page_name
        parser = AssetParser()
        parser.feed(page.read_text(encoding="utf-8"))
        assert NAV_TARGETS.issubset({x.split("#", 1)[0] for x in parser.links}), f"incomplete nav: {page_name}"
        for ref in parser.assets + parser.links:
            target = local_target(ref)
            if target:
                assert (ROOT / target).is_file(), f"broken local target {ref} in {page_name}"
        text = page.read_text(encoding="utf-8")
        assert "assets/auth.js" not in text
        assert "assets/account.js?v=2" in text
        assert "assets/account.css?v=2" in text

    mapping = (ROOT / "mapping.html").read_text(encoding="utf-8")
    for expected in ["17,095 catalog objects", "17,094", "143,082", "3,150", "4,734", "9,210",
                     "Schema-confirmed", "Procedure-confirmed", "Key-grain inferred",
                     "no SysDrTables or SysDrColumns", "not equivalents", "CandidateGrain",
                     "cannot validate backward NPR lineage", "OrphanRows", "AmbiguousParentRows",
                     "MaxParentMatches"]:
        assert expected in mapping
    explorer = (ROOT / "explorer.html").read_text(encoding="utf-8")
    assert "Exclude empty / near-empty" in explorer
    assert "return (DATA.topics || []).find" in explorer
    topics_page = (ROOT / "topics.html").read_text(encoding="utf-8")
    assert topics_page.count('class="chip row-badge"') == 2
    server = (ROOT / "server.js").read_text(encoding="utf-8")
    assert 'AUTH_ALLOWED_EMAIL_DOMAIN || "gcp.cdio.aku.edu"' in server
    assert "Strict-Transport-Security" in server
    assert "Cross-Origin-Resource-Policy" in server
    print("PASS: production contract, 8 pages, 54 topics, 261 tables, 645 relationships, 63 SQL assets")


if __name__ == "__main__":
    main()
