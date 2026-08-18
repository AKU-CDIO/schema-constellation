#!/usr/bin/env python3
"""Publish SP source and evidence-backed topic relationships for Explorer.

The browser never reads the private dev directory. This build step exposes the
checked-in SQL as a static data asset, extracts procedure-confirmed joins, and
creates an evidence-labelled topic graph. INFORMATION_SCHEMA-compatible key
matches are used only when no procedure or curated relationship is available;
an unresolved topic membership is emitted as an association, never as a join.
"""
from __future__ import annotations

import collections
import datetime as dt
import glob
import io
import json
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCHEMA_PATH = os.path.join(ROOT, "data", "schema.js")
PHASES_PATH = os.path.join(ROOT, "data", "phases.js")
SQL_DIR = os.path.join(ROOT, "dev", "fcap1a_utf8")
PREFERRED_SQL_DIR = os.environ.get(
    "FCAP1A_PREFERRED_SQL_DIR",
    r"C:\Users\derick.imbati\OneDrive - Aga Khan University\Documents\MasterPiece\MAYO\Cohort_Data_Sets\sps",
)
OUT_PATH = os.path.join(ROOT, "data", "sp_source.js")

KEY_ORDER = ["SourceID", "PatientID", "VisitID"]
SQL_KEYWORDS = {"as", "cross", "full", "inner", "join", "left", "on", "outer", "right", "where", "with", "group", "order", "union", "having"}
EVIDENCE_RANK = {"procedure": 6, "curated": 5, "schema-fk": 4, "table-family": 4, "key-grain": 3, "information-schema-key-match": 2, "topic-contract": 1}


def load_js(path, variable):
    text = io.open(path, encoding="utf-8").read()
    match = re.search(rf"window\.{re.escape(variable)}\s*=\s*(\{{.*\}});", text, re.S)
    if not match:
        raise SystemExit(f"Could not parse {path}")
    return json.loads(match.group(1))


def identifier_parts(token):
    return [part.strip().strip("[]") for part in re.split(r"\s*\.\s*", token)]


TABLE_ALIAS_RE = re.compile(
    r"\b(?:FROM|(?:INNER|LEFT|RIGHT|FULL|CROSS)\s+JOIN|JOIN)\s+"
    r"(?!\()((?:\[[^\]]+\]|[A-Za-z0-9_]+)(?:\s*\.\s*(?:\[[^\]]+\]|[A-Za-z0-9_]+)){0,3})"
    r"(?:\s+(?:AS\s+)?([A-Za-z][A-Za-z0-9_]*))?", re.I)
EQUALITY_RE = re.compile(
    r"\b([A-Za-z][A-Za-z0-9_]*)\.\[?([A-Za-z0-9_]+)\]?"
    r"(?:\s+COLLATE\s+[A-Za-z0-9_]+)?\s*=\s*"
    r"([A-Za-z][A-Za-z0-9_]*)\.\[?([A-Za-z0-9_]+)\]?", re.I)


def parse_procedure_name(text, fallback):
    match = re.search(r"(?:CREATE\s+OR\s+ALTER|CREATE|ALTER)\s+PROCEDURE\s+(?:\[?dbo\]?\.)?\[?([A-Za-z0-9_]+)\]?", text, re.I)
    return match.group(1) if match else fallback


def parse_author(text):
    match = re.search(r"(?im)^[\s/*-]*Author\b\s*:?\s*([^\r\n*]+)", text)
    return match.group(1).strip().rstrip("*/ ") if match else None


def resolve_sql_path(filename):
    preferred = os.path.join(PREFERRED_SQL_DIR, filename)
    if os.path.isfile(preferred):
        return preferred
    return os.path.join(SQL_DIR, filename)


def extract_joins(text, tables, asset_id):
    aliases = collections.defaultdict(set)
    for match in TABLE_ALIAS_RE.finditer(text):
        table = identifier_parts(match.group(1))[-1]
        alias = (match.group(2) or table).strip("[]")
        if alias.lower() in SQL_KEYWORDS:
            alias = table
        if table in tables:
            aliases[alias.lower()].add(table)
            aliases[table.lower()].add(table)

    grouped = collections.defaultdict(list)
    for match in EQUALITY_RE.finditer(text):
        left_alias, left_col, right_alias, right_col = match.groups()
        left_tables = aliases.get(left_alias.lower(), set())
        right_tables = aliases.get(right_alias.lower(), set())
        if len(left_tables) != 1 or len(right_tables) != 1:
            continue
        left, right = next(iter(left_tables)), next(iter(right_tables))
        if left == right or tables[left].get("role") == "cohort" or tables[right].get("role") == "cohort":
            continue
        pair = {"from_col": left_col, "to_col": right_col}
        if pair not in grouped[(left, right)]:
            grouped[(left, right)].append(pair)

    joins = []
    for (left, right), keys in grouped.items():
        same = [key["from_col"] for key in keys if key["from_col"] == key["to_col"]]
        different = [f"{key['from_col']} = {key['to_col']}" for key in keys if key["from_col"] != key["to_col"]]
        joins.append({
            "from": left, "to": right, "on": " + ".join(same + different), "keys": keys,
            "card": "N:1", "kind": "join", "evidence": "procedure", "confidence": "high", "graph": True,
            "asset": asset_id, "note": f"Join read from {asset_id}.sql.",
        })
    return joins


def column_names(table):
    return {column.get("n") for column in table.get("cols", []) if column.get("n")}


def suffix_matches(left, right):
    candidates = []
    for left_col in sorted(column_names(left)):
        if not left_col.lower().endswith("id"):
            continue
        for right_col in sorted(column_names(right)):
            if not right_col.lower().endswith("id"):
                continue
            if left_col == right_col or left_col.endswith("_" + right_col) or right_col.endswith("_" + left_col):
                candidates.append({"from_col": left_col, "to_col": right_col})
    return candidates


def select_inferred_keys(left, right):
    matches = suffix_matches(left, right)
    exact = {item["from_col"]: item for item in matches if item["from_col"] == item["to_col"]}
    if "PatientID" in exact and "VisitID" in exact:
        return [exact[key] for key in ("SourceID", "PatientID", "VisitID") if key in exact]
    if "SourceID" in exact and "VisitID" in exact:
        return [exact["SourceID"], exact["VisitID"]]
    if "SourceID" in exact and "PatientID" in exact:
        return [exact["SourceID"], exact["PatientID"]]
    business = [item for item in matches if item["from_col"] not in KEY_ORDER]
    if business:
        return ([exact["SourceID"]] if "SourceID" in exact else []) + business[:2]
    if "PatientID" in exact:
        return [exact["PatientID"]]
    if "VisitID" in exact:
        return [exact["VisitID"]]
    return []


def on_text(keys):
    return " + ".join(key["from_col"] if key["from_col"] == key["to_col"] else f"{key['from_col']} = {key['to_col']}" for key in keys)


def relation_keys(rel):
    if rel.get("keys"):
        return rel["keys"]
    keys = []
    for part in re.split(r"\s*\+\s*", str(rel.get("on") or "")):
        if not part or part.lower() in {"procedure lineage", "build run", "topic membership"}:
            continue
        if "=" in part:
            left, right = [item.strip().strip("[]") for item in part.split("=", 1)]
        else:
            left = right = part.strip().strip("[]")
        if re.fullmatch(r"[A-Za-z0-9_]+", left) and re.fullmatch(r"[A-Za-z0-9_]+", right):
            keys.append({"from_col": left, "to_col": right})
    return keys


def relationship_key(rel):
    return tuple(sorted((rel["from"], rel["to"])))


def prefer_relation(existing, candidate):
    if existing is None:
        return candidate
    old = (1 if existing.get("kind") == "join" and relation_keys(existing) else 0, EVIDENCE_RANK.get(existing.get("evidence"), 0), len(relation_keys(existing)))
    new = (1 if candidate.get("kind") == "join" and relation_keys(candidate) else 0, EVIDENCE_RANK.get(candidate.get("evidence"), 0), len(relation_keys(candidate)))
    return candidate if new > old else existing


def inferred_relation(left_name, right_name, tables):
    left_is_dictionary = bool(re.match(r"^(D[A-Z]|Mis|Unv)", left_name) or "Dict" in left_name)
    right_is_dictionary = bool(re.match(r"^(D[A-Z]|Mis|Unv)", right_name) or "Dict" in right_name)
    keys = select_inferred_keys(tables[left_name], tables[right_name])
    if not keys:
        return None
    # Sparse catalog extracts can expose generic PatientID/VisitID markers on
    # dictionary-looking tables. Do not promote those markers into a join.
    if (left_is_dictionary or right_is_dictionary) and all(key["from_col"] in KEY_ORDER and key["to_col"] in KEY_ORDER for key in keys):
        return None
    return {
        "from": left_name, "to": right_name, "on": on_text(keys), "keys": keys,
        "card": "N:1", "kind": "join", "evidence": "information-schema-key-match",
        "confidence": "review-required", "graph": True,
        "note": "Candidate relationship inferred from matching INFORMATION_SCHEMA column names; run the relationship gate before production use.",
    }


def topic_context(topic, tables, static_rels, assets):
    members = [name for name in topic.get("tables", []) if name in tables and tables[name].get("role") != "cohort"]
    ids = list(dict.fromkeys(members + ["HimRec_Main"]))
    if any("VisitID" in column_names(tables[name]) for name in members):
        ids.extend(["AdmVisits", "RegAcct_Main"])
    ids = [name for name in dict.fromkeys(ids) if name in tables and tables[name].get("role") != "cohort"]
    id_set = set(ids)
    selected = {}

    for rel in static_rels:
        if rel.get("kind", "join") != "join" or rel["from"] not in id_set or rel["to"] not in id_set:
            continue
        item = dict(rel)
        item["keys"] = relation_keys(item)
        left_cols, right_cols = column_names(tables[item["from"]]), column_names(tables[item["to"]])
        if item["keys"] and not all(key["from_col"] in left_cols and key["to_col"] in right_cols for key in item["keys"]):
            item["keys"] = []
            item["kind"] = "association"
            item["confidence"] = "unresolved"
            item["note"] = (item.get("note") or "") + " The shorthand key could not be validated against both supplied column lists."
        selected[relationship_key(item)] = prefer_relation(selected.get(relationship_key(item)), item)
    for asset_id in (topic.get("sp") or {}).get("assets", []):
        for rel in assets.get(asset_id, {}).get("joins", []):
            if rel["from"] in id_set and rel["to"] in id_set:
                selected[relationship_key(rel)] = prefer_relation(selected.get(relationship_key(rel)), rel)

    def degree(name, joins_only=False):
        return sum(1 for rel in selected.values() if name in (rel["from"], rel["to"]) and (not joins_only or rel.get("kind") == "join"))

    anchors = [name for name in ("HimRec_Main", "AdmVisits", "RegAcct_Main") if name in id_set]
    for member in members:
        if degree(member, True):
            continue
        candidates = []
        for other in ids:
            if other == member:
                continue
            rel = inferred_relation(member, other, tables)
            if rel:
                key_names = {key["from_col"] for key in rel["keys"]} | {key["to_col"] for key in rel["keys"]}
                score = len(rel["keys"]) * 10 + (8 if other in anchors else 0)
                score += 22 if other == "AdmVisits" and {"PatientID", "VisitID"}.issubset(key_names) and "SourceID" not in key_names else 0
                score += 22 if other == "RegAcct_Main" and {"SourceID", "VisitID"}.issubset(key_names) else 0
                score += 22 if other == "HimRec_Main" and "PatientID" in key_names and "VisitID" not in key_names else 0
                score -= 20 if other == "HimRec_Main" and "VisitID" in key_names else 0
                candidates.append((score, rel))
        if candidates:
            _, rel = max(candidates, key=lambda item: item[0])
            selected[relationship_key(rel)] = prefer_relation(selected.get(relationship_key(rel)), rel)
        else:
            anchor = anchors[0] if anchors else ids[0]
            rel = {
                "from": anchor, "to": member, "on": "topic membership", "keys": [], "card": "unresolved",
                "kind": "association", "evidence": "topic-contract", "confidence": "unresolved", "graph": True,
                "note": "This source contributes to the topic, but no validated join key is present in the supplied catalog or procedure SQL.",
            }
            selected[relationship_key(rel)] = rel

    def components():
        graph = {name: set() for name in ids}
        for rel in selected.values():
            if rel.get("kind") != "join" or not relation_keys(rel):
                continue
            graph[rel["from"]].add(rel["to"])
            graph[rel["to"]].add(rel["from"])
        result, seen = [], set()
        for name in ids:
            if name in seen:
                continue
            stack, component = [name], set()
            while stack:
                current = stack.pop()
                if current in component:
                    continue
                component.add(current)
                stack.extend(sorted(graph[current] - component))
            seen.update(component)
            result.append(component)
        return result

    while True:
        comps = components()
        if len(comps) <= 1:
            break
        candidates = []
        for index, left_comp in enumerate(comps):
            for right_comp in comps[index + 1:]:
                for left in sorted(left_comp):
                    for right in sorted(right_comp):
                        rel = inferred_relation(left, right, tables)
                        if rel:
                            key_names = {key["from_col"] for key in rel["keys"]} | {key["to_col"] for key in rel["keys"]}
                            score = len(rel["keys"]) * 10 + (8 if left in anchors or right in anchors else 0)
                            score += 18 if "AdmVisits" in (left, right) and {"PatientID", "VisitID"}.issubset(key_names) and "SourceID" not in key_names else 0
                            score += 18 if "RegAcct_Main" in (left, right) and {"SourceID", "VisitID"}.issubset(key_names) else 0
                            score -= 18 if "HimRec_Main" in (left, right) and "VisitID" in key_names else 0
                            candidates.append((score, rel))
        if not candidates:
            break
        _, rel = max(candidates, key=lambda item: item[0])
        selected[relationship_key(rel)] = prefer_relation(selected.get(relationship_key(rel)), rel)

    # The default Explorer hides empty and near-empty sources. Ensure every
    # node that remains visible still has a visible line; use an association
    # when filtering removed its only evidence-backed neighbour.
    def usable(name):
        count = tables[name].get("row_count")
        return count is None or int(count) >= 1000 or name in anchors

    visible_ids = [name for name in ids if usable(name)]
    for node in visible_ids:
        has_visible_edge = any(node in (rel["from"], rel["to"]) and rel["from"] in visible_ids and rel["to"] in visible_ids for rel in selected.values())
        if has_visible_edge or len(visible_ids) < 2:
            continue
        target = "HimRec_Main" if node != "HimRec_Main" and "HimRec_Main" in visible_ids else next(name for name in visible_ids if name != node)
        rel = {
            "from": target, "to": node, "on": "topic membership", "keys": [], "card": "unresolved",
            "kind": "association", "evidence": "topic-contract", "confidence": "unresolved", "graph": True,
            "note": "Default row-count filtering removed this node's only joined neighbour; the dashed line preserves topic context without claiming a SQL join.",
        }
        selected[relationship_key(rel)] = prefer_relation(selected.get(relationship_key(rel)), rel)

    rels = list(selected.values())
    rels.sort(key=lambda rel: (0 if rel.get("kind") == "join" else 1, -EVIDENCE_RANK.get(rel.get("evidence"), 0), rel["from"], rel["to"], rel.get("on", "")))
    return {"ids": ids, "members": members, "relationships": rels}


def build_query(topic, context, tables):
    ids, members = context["ids"], set(context["members"])
    if not ids:
        return "-- No relational source tables are available for this topic."
    root = "HimRec_Main" if "HimRec_Main" in ids else ids[0]
    adjacency = collections.defaultdict(list)
    for rel in context["relationships"]:
        if rel.get("kind") == "join" and relation_keys(rel):
            adjacency[rel["from"]].append(rel)
            adjacency[rel["to"]].append(rel)
    queue, seen, tree = [root], {root}, []
    while queue:
        current = queue.pop(0)
        edges = sorted(adjacency[current], key=lambda rel: (-EVIDENCE_RANK.get(rel.get("evidence"), 0), -len(relation_keys(rel))))
        for rel in edges:
            other = rel["to"] if rel["from"] == current else rel["from"]
            if other in seen:
                continue
            seen.add(other)
            queue.append(other)
            tree.append((current, other, rel))

    aliases = {root: "t0"}
    lines = [
        f"-- {topic['name']} - read-only topic assembly query",
        "-- Procedure-confirmed joins are preferred; inferred joins are explicitly marked.",
        "-- Run the Data Mapping relationship gate before production use.",
        "SELECT TOP (100)", "       t0.*",
        f"FROM [{tables[root].get('db', 'AKULiveATdb')}].[dbo].[{root}] AS t0",
    ]
    for parent, child, rel in tree:
        aliases.setdefault(parent, f"t{len(aliases)}")
        aliases.setdefault(child, f"t{len(aliases)}")
        parent_alias, child_alias = aliases[parent], aliases[child]
        oriented = relation_keys(rel) if rel["from"] == parent else [{"from_col": key["to_col"], "to_col": key["from_col"]} for key in relation_keys(rel)]
        conditions = [f"{child_alias}.[{key['to_col']}] = {parent_alias}.[{key['from_col']}]" for key in oriented]
        lines.append(f"LEFT JOIN [{tables[child].get('db', 'AKULiveATdb')}].[dbo].[{child}] AS {child_alias}")
        lines.append(f"  ON {' AND '.join(conditions)} -- {rel.get('evidence', 'curated')}; {rel.get('confidence', 'high')}")
    unresolved = sorted(members - seen)
    lines.append(";")
    if unresolved:
        lines.extend(["-- Not joined: no validated key path is present in the supplied evidence.", "-- Inspect separately before adding these sources:"])
        for name in unresolved:
            lines.append(f"-- SELECT TOP (100) * FROM [{tables[name].get('db', 'AKULiveATdb')}].[dbo].[{name}];")
    return "\n".join(lines)


def main():
    schema = load_js(SCHEMA_PATH, "SCHEMA_DATA")
    phases = load_js(PHASES_PATH, "SCHEMA_PHASES")
    tables, assets = schema["tables"], {}
    for path in sorted(glob.glob(os.path.join(SQL_DIR, "*.sql"))):
        filename = os.path.basename(path)
        asset_id = os.path.splitext(filename)[0]
        resolved_path = resolve_sql_path(filename)
        sql = io.open(resolved_path, encoding="utf-8-sig", errors="replace").read().replace("\r\n", "\n")
        author = parse_author(sql)
        if author is None and resolved_path != path:
            fallback_sql = io.open(path, encoding="utf-8-sig", errors="replace").read().replace("\r\n", "\n")
            author = parse_author(fallback_sql)
        if author is None:
            author = "test"
        assets[asset_id] = {
            "id": asset_id,
            "name": parse_procedure_name(sql, asset_id),
            "file": filename,
            "source_file": resolved_path,
            "author": author,
            "sql": sql,
            "joins": extract_joins(sql, tables, asset_id),
        }
    topics = {}
    for topic in [topic for phase in phases["phases"] for topic in phase["topics"]]:
        context = topic_context(topic, tables, schema.get("rels", []), assets)
        context["query"] = build_query(topic, context, tables)
        topics[topic["id"]] = context
    payload = {
        "meta": {"generated": dt.date.today().isoformat(), "asset_count": len(assets), "topic_count": len(topics), "relationship_count": sum(len(topic["relationships"]) for topic in topics.values()), "method": "stored-procedure SQL joins + curated relationships + INFORMATION_SCHEMA key-match fallback"},
        "assets": assets, "topics": topics,
    }
    with io.open(OUT_PATH, "w", encoding="utf-8", newline="\n") as handle:
        handle.write("window.SP_SOURCE = ")
        handle.write(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
        handle.write(";\n")
    unresolved = sum(1 for topic in topics.values() for rel in topic["relationships"] if rel.get("kind") == "association")
    print(f"wrote {OUT_PATH}")
    print(f"assets={len(assets)} topics={len(topics)} relationships={payload['meta']['relationship_count']} unresolved_associations={unresolved}")


if __name__ == "__main__":
    main()
