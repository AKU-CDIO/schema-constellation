# -*- coding: utf-8 -*-
"""Finalize schema metadata, lineage, and relationship coverage.

This pass preserves the hand-curated graph, adds SQL-backed output lineage,
adds schema-backed foreign-key links, and adds hidden grain links so every
patient/visit table has an auditable route to its hub or encounter spine.
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
SQL_DIR = os.path.join(ROOT, "dev", "fcap1a_utf8")
REMAINING_SOURCE_PATH = os.path.join(ROOT, "dev", "remaining_source_metadata.json")
SOURCE_ROW_COUNTS_PATH = os.path.join(ROOT, "dev", "source_row_counts.json")


# The full catalog extraction adds sources that were not part of the original
# curated graph. Keep their product-domain classification here so a future
# regeneration cannot introduce an unknown ``remaining`` topic and break the
# Explorer at startup.
REMAINING_TABLE_CONTRACTS = {
    "AmbPatCm_PregnancyData": ("encounter", "entity", "encounter", "Pregnancy episode detail", "Pregnancy dates, status, fetal count, estimated delivery date, and obstetric episode attributes per patient."),
    "AmbPatCm_PregnancyMain": ("encounter", "entity", "encounter", "Pregnancy summary", "Patient-level active pregnancy summary and active pregnancy protocol."),
    "AmbPatCm_PregnancyNonVisitLog": ("encounter", "entity", "encounter", "Pregnancy non-visit log", "Pregnancy events documented outside a registered visit; low-volume and excluded from default populated views."),
    "AmbPatCm_PregnancyVisitLog": ("encounter", "entity", "encounter", "Pregnancy visit linkage", "Links a pregnancy episode to its registration account through PregnancyVisit_RegAcctID."),
    "CmgDevices_DevicePatHistory": ("careplan", "entity", "clinical", "Loaned device patient history", "Patient loan and return history for care-management devices; currently empty in the audited source."),
    "CwsAppt_AuditTrail": ("encounter", "entity", "encounter", "Appointment audit trail", "Appointment changes, users, timestamps, reasons, locations, and registration-account references."),
    "CwsAppt_Main_ApptComments": ("encounter", "entity", "encounter", "Appointment comments", "Sequenced free-text comments attached to an appointment; low-volume in the audited source."),
    "CwsAppt_Participants": ("encounter", "entity", "encounter", "Appointment participants", "Participant type and participant value attached to an appointment; near-empty in the audited source."),
    "CwsAppt_Resources": ("encounter", "entity", "encounter", "Appointment resources", "Rooms, resource groups, start times, durations, and resource types allocated to appointments."),
    "EmrParam_AmbCanRegSocHis": ("identity", "dict", "dictionary", "Ambulatory social-history parameters", "Facility configuration that points to social-history, occupation, and industry query definitions."),
    "EmrParam_CcdFacilityGroups": ("identity", "dict", "dictionary", "CCD facility-group parameters", "Facility-group query mappings for smoking, pregnancy, ethnicity, race, and gender; currently empty."),
    "EmrParam_CcdSocHistoryQrys": ("identity", "dict", "dictionary", "CCD social-history query map", "Configured CCD social-history query identifiers and sort order; currently empty."),
    "EmrParam_PhsSocHistoryQrys": ("identity", "dict", "dictionary", "PHS social-history query map", "Configured PHS social-history query identifiers and sort order; currently empty."),
    "MisQry_Main": ("identity", "dict", "dictionary", "Query dictionary", "Master definitions for configured patient and account questions, including text, type, response behavior, and NPR pointers."),
    "PcsMarAct_BagInfusionLastDoc": ("medication", "entity", "clinical", "Last documented bag infusion", "Latest documented infusion rate, volume, status, user, and timing for each medication bag."),
    "PcsMarAct_MarActivityTitr": ("medication", "entity", "clinical", "MAR titration activity", "Event-level infusion titration documentation, users, timestamps, clinical events, and IV smart-pump references."),
    "PcsMarAct_MarLastDocumented": ("medication", "entity", "clinical", "Last documented MAR activity", "Latest medication administration and infusion dose, rate, volume, status, and documentation attributes per visit."),
    "PcsMarAct_MarLastTitration": ("medication", "entity", "clinical", "Last documented titration", "Latest titration dose, rate, units, infusion status, and volume attributes per visit."),
    "PcsMarAct_MarMeds": ("medication", "entity", "clinical", "MAR medication detail", "Medication mnemonic, generic name, trade name, and order-dictionary mapping for medication-administration records."),
    "PcsMarAct_MarRxs": ("medication", "entity", "clinical", "MAR prescription detail", "Route, prescription type, medication strings, titration units, and IV documentation controls per visit."),
    "SurCase_ActualProcs": ("careplan", "entity", "clinical", "Surgical actual procedures", "Actual procedures, primary/secondary status, surgeon, laterality, wound class, severity, and procedure timing."),
    "SurCase_ActualProcSurgTimes": ("careplan", "entity", "clinical", "Procedure surgeon times", "Surgeon start and through timestamps for an actual surgical procedure."),
    "SurCase_Implant": ("careplan", "entity", "clinical", "Surgical implants", "Implant identity, quantity, manufacturer, lot, serial, site, expiry, charge, and device-identifier details."),
}


def load_schema():
    text = io.open(SCHEMA_PATH, encoding="utf-8").read()
    match = re.search(r"window\.SCHEMA_DATA\s*=\s*(\{.*\});", text, re.S)
    if not match:
        raise SystemExit("Could not parse data/schema.js")
    return json.loads(match.group(1))


def balanced_body(text, start):
    depth = 0
    for index in range(start, len(text)):
        char = text[index]
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return text[start + 1:index]
    return ""


def split_top_level(body):
    chunks, current, depth = [], [], 0
    for char in body:
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
        if char == "," and depth == 0:
            chunks.append("".join(current))
            current = []
        else:
            current.append(char)
    if current:
        chunks.append("".join(current))
    return chunks


def parse_create_tables(text):
    outputs = {}
    pattern = re.compile(
        r"CREATE\s+TABLE\s+(?:\[?dbo\]?\.)?\[?(tbl_FCAP1A_[A-Za-z0-9_]+)\]?\s*\(",
        re.I,
    )
    for match in pattern.finditer(text):
        name = match.group(1)
        body = balanced_body(text, match.end() - 1)
        cols, pk = [], []
        for chunk in split_top_level(body):
            item = " ".join(chunk.strip().split())
            column_match = re.match(
                r"\[?([A-Za-z0-9_]+)\]?\s+([A-Za-z0-9_]+)(?:\s*\(([^)]*)\))?",
                item,
                re.I,
            )
            if not column_match:
                continue
            column, sql_type, arg = column_match.groups()
            if column.upper() in {"CONSTRAINT", "PRIMARY", "UNIQUE", "FOREIGN", "CHECK"}:
                continue
            length = int(arg.strip()) if arg and arg.strip().isdigit() else None
            cols.append({
                "n": column,
                "t": sql_type.lower(),
                "len": length,
                "nn": bool(re.search(r"\bNOT\s+NULL\b", item, re.I)),
                "fk": None,
            })
            if re.search(r"\bPRIMARY\s+KEY\b", item, re.I):
                pk.append(column)
        outputs[name] = {"cols": cols, "pk": pk}
    return outputs


def table_refs(text):
    refs = []
    pattern = re.compile(
        r"\[(AKULiveATdb|AKULivendb|CDIO_MeditechDB)\]\s*\.\s*"
        r"(?:\[?dbo\]?\s*\.\s*)?\[?([A-Za-z0-9_]+)\]?",
        re.I,
    )
    for database, table in pattern.findall(text):
        pair = (database, table)
        if pair not in refs:
            refs.append(pair)
    return refs


def asset_kind(filename):
    lower = filename.lower()
    if lower.startswith("usp_build_"):
        return "build"
    if lower.startswith("usp_run_"):
        return "orchestration"
    if "metadata" in lower:
        return "metadata"
    if "hash" in lower:
        return "utility"
    return "supporting"


def parse_sql_assets(tables):
    assets, db_votes = [], collections.defaultdict(collections.Counter)
    for path in sorted(glob.glob(os.path.join(SQL_DIR, "*.sql"))):
        filename = os.path.basename(path)
        text = io.open(path, encoding="utf-8-sig", errors="replace").read()
        created = parse_create_tables(text)
        refs = table_refs(text)
        for database, table in refs:
            if table in tables:
                db_votes[table][database] += 1
        procedure_match = re.search(
            r"(?:CREATE\s+OR\s+ALTER|CREATE|ALTER)\s+PROCEDURE\s+"
            r"(?:\[?dbo\]?\.)?\[?([A-Za-z0-9_]+)\]?",
            text,
            re.I,
        )
        outputs = list(created)
        for output in re.findall(r"INSERT\s+INTO\s+(?:\[?dbo\]?\.)?\[?(tbl_FCAP1A_[A-Za-z0-9_]+)\]?", text, re.I):
            if output not in outputs:
                outputs.append(output)
        source_names = []
        for _, table in refs:
            if table in tables and table not in outputs and not table.startswith("tbl_FCAP1A_"):
                if table not in source_names:
                    source_names.append(table)
        asset_id = os.path.splitext(filename)[0]
        assets.append({
            "id": asset_id,
            "name": procedure_match.group(1) if procedure_match else asset_id,
            "file": filename,
            "kind": asset_kind(filename),
            "implemented": True,
            "sources": source_names,
            "outputs": outputs,
        })
        for output, definition in created.items():
            if output not in tables:
                label = output.replace("tbl_FCAP1A_", "FCAP1A ").replace("_", " ")
                tables[output] = {
                    "name": output,
                    "label": label,
                    "desc": "Cohort output created by " + asset_id + ".",
                    "role": "cohort",
                    "topic": "pipeline",
                    "zone": "pipeline",
                    "pk": definition["pk"],
                    "cols": definition["cols"],
                    "db": "CDIO_MeditechDB",
                    "dbs": ["CDIO_MeditechDB"],
                }
    return assets, db_votes


def column_names(table):
    return {col.get("n") for col in table.get("cols", []) if isinstance(col, dict)}


def has_cols(table, *names):
    return set(names).issubset(column_names(table))


def main():
    data = load_schema()
    tables = data["tables"]
    if os.path.exists(REMAINING_SOURCE_PATH):
        with io.open(REMAINING_SOURCE_PATH, encoding="utf-8") as handle:
            remaining_sources = json.load(handle)
        for name in list(tables):
            if tables[name].get("topic") == "remaining" and name not in remaining_sources:
                del tables[name]
        for name, definition in remaining_sources.items():
            contract = REMAINING_TABLE_CONTRACTS.get(name)
            if contract:
                topic, role, zone, label, description = contract
                definition = dict(definition)
                definition.update({
                    "topic": topic,
                    "role": role,
                    "zone": zone,
                    "label": label,
                    "desc": description,
                })
            if name not in tables or len(definition.get("cols", [])) > len(tables[name].get("cols", [])):
                tables[name] = definition
            elif contract:
                for field in ("topic", "role", "zone", "label", "desc"):
                    tables[name][field] = definition[field]
    assets, db_votes = parse_sql_assets(tables)

    source_counts = {"near_empty_threshold": 1000, "tables": {}}
    if os.path.exists(SOURCE_ROW_COUNTS_PATH):
        with io.open(SOURCE_ROW_COUNTS_PATH, encoding="utf-8") as handle:
            source_counts = json.load(handle)
    counts_by_name = collections.defaultdict(list)
    for qualified, count_data in source_counts.get("tables", {}).items():
        counts_by_name[qualified.rsplit(".", 1)[-1]].append((qualified, count_data))

    for name, table in tables.items():
        if table.get("role") == "cohort":
            table["db"] = "CDIO_MeditechDB"
            table["dbs"] = ["CDIO_MeditechDB"]
            continue
        votes = db_votes.get(name)
        database = votes.most_common(1)[0][0] if votes else "AKULiveATdb"
        table["db"] = database
        table["dbs"] = sorted(votes) if votes else [database]
        candidates = counts_by_name.get(name, [])
        selected = next((value for qualified, value in candidates if qualified.startswith(database + ".")), None)
        if selected is None and len(candidates) == 1:
            selected = candidates[0][1]
        if selected is not None:
            table["row_count"] = selected.get("rows")
            table["catalog_column_count"] = selected.get("columns")
            table["row_quality"] = selected.get("quality")
            table["default_visible"] = selected.get("default_visible", True)

    rels = data["rels"]
    for rel in rels:
        source_role = tables[rel["from"]].get("role")
        target_role = tables[rel["to"]].get("role")
        if source_role == "cohort" or target_role == "cohort":
            rel.setdefault("kind", "lineage")
            rel.setdefault("evidence", "procedure" if source_role != "cohort" else "pipeline")
        else:
            rel.setdefault("kind", "join")
            rel.setdefault("evidence", "curated")
        rel.setdefault("confidence", "high")
        rel.setdefault("graph", True)

    def relation_exists(left, right):
        return any({rel["from"], rel["to"]} == {left, right} for rel in rels)

    def add_relation(left, right, on, card, note, evidence, confidence="medium", graph=False, kind="join", asset=None):
        if left not in tables or right not in tables or left == right or relation_exists(left, right):
            return False
        rel = {
            "from": left,
            "to": right,
            "on": on,
            "card": card,
            "note": note,
            "kind": kind,
            "evidence": evidence,
            "confidence": confidence,
            "graph": graph,
        }
        if asset:
            rel["asset"] = asset
        rels.append(rel)
        return True

    for asset in assets:
        for output in asset["outputs"]:
            if output not in tables:
                continue
            out_table = tables[output]
            for source in asset["sources"]:
                source_table = tables[source]
                if has_cols(source_table, "SourceID", "VisitID") and has_cols(out_table, "SourceID", "VisitID"):
                    on = "SourceID + VisitID"
                elif has_cols(source_table, "SourceID", "PatientID") and has_cols(out_table, "SourceID", "PatientID"):
                    on = "SourceID + PatientID"
                else:
                    on = "procedure lineage"
                add_relation(source, output, on, "N:1", f"{asset['name']} reads {source} to build {output}.", "procedure", "high", True, "lineage", asset["id"])

    for child, table in list(tables.items()):
        if table.get("role") == "cohort":
            continue
        for col in table.get("cols", []):
            parent = col.get("fk") if isinstance(col, dict) else None
            if parent not in tables or tables[parent].get("role") == "cohort":
                continue
            key = col.get("n")
            label = ("SourceID + " + key) if has_cols(table, "SourceID") and has_cols(tables[parent], "SourceID") else key
            add_relation(parent, child, label, "1:N", f"{child}.{key} references {parent}; derived from the schema column FK hint.", "schema-fk")

    source_names = [name for name, table in tables.items() if table.get("role") != "cohort"]
    for child in source_names:
        child_cols = column_names(tables[child])
        candidates = []
        for parent in source_names:
            if parent == child:
                continue
            parent_root = parent[:-5] if parent.endswith("_Main") else parent
            if child.startswith(parent + "_") or child.startswith(parent_root + "_"):
                shared = [key for key in tables[parent].get("pk", []) if key in child_cols]
                if "SourceID" in child_cols and "SourceID" in column_names(tables[parent]) and "SourceID" not in shared:
                    shared.insert(0, "SourceID")
                if len(shared) >= 2 or (shared and shared != ["SourceID"]):
                    candidates.append((len(parent_root), parent, shared))
        if candidates:
            _, parent, shared = max(candidates)
            add_relation(parent, child, " + ".join(shared), "1:N", f"{child} is a keyed detail/extension of {parent}; shared key columns: {', '.join(shared)}.", "table-family", "high")

    for name in source_names:
        table = tables[name]
        if name != "HimRec_Main" and table.get("role") != "dict" and has_cols(table, "SourceID", "PatientID"):
            add_relation("HimRec_Main", name, "SourceID + PatientID", "1:N", f"{name} carries the universal patient grain and resolves to the master patient hub.", "key-grain")
        if table.get("role") != "dict" and has_cols(table, "SourceID", "VisitID"):
            spine = "RegAcct_Main" if re.match(r"^(RegAcct_|PcsAcct|OmOrd|Pth|ItsResult|EmrAcctRep|BarAcct|SurCase|CwsAppt)", name) else "AdmVisits"
            if name != spine:
                add_relation(spine, name, "SourceID + VisitID", "1:N", f"{name} carries visit grain and resolves to the {spine} encounter spine.", "key-grain")

    if "FCAP1A_Cohort_Log" in tables and not any("FCAP1A_Cohort_Log" in (rel["from"], rel["to"]) for rel in rels):
        add_relation("tbl_FCAP1A_Cohort10_Extended", "FCAP1A_Cohort_Log", "build run", "1:N", "Every FCAP1A build records run status and row counts in the shared cohort log.", "pipeline", "high", False, "lineage")

    data["procedures"] = assets
    evidence_counts = collections.Counter(rel["evidence"] for rel in rels)
    kind_counts = collections.Counter(rel["kind"] for rel in rels)
    data["meta"]["generated"] = dt.date.today().isoformat()
    data["meta"]["source"] = "INFORMATION_SCHEMA.COLUMNS workbook (info_schema.csv, XLSX content) + %d FCAP1A SQL assets" % len(assets)
    source_quality = collections.Counter(
        table.get("row_quality", "unknown") for table in tables.values() if table.get("role") != "cohort"
    )
    data["meta"]["row_count_model"] = {
        "near_empty_threshold": source_counts.get("near_empty_threshold", 1000),
        "curated_sources": sum(source_quality.values()), "by_quality": dict(sorted(source_quality.items())),
        "default": "hide empty and near-empty source tables",
    }
    data["meta"]["relationship_model"] = {
        "total": len(rels),
        "by_kind": dict(sorted(kind_counts.items())),
        "by_evidence": dict(sorted(evidence_counts.items())),
        "default_graph": sum(rel.get("graph", True) for rel in rels),
    }
    data["meta"]["notes"] = [
        "Join relationships and stored-procedure lineage are modeled separately.",
        "Patient grain uses SourceID + PatientID; visit grain uses SourceID + VisitID.",
        "Generated key-grain and schema-FK links are hidden from the default overview but remain available in table detail and the all-links view.",
        "Analysis window: 2022-11-05 to 2026-06-14 (FCAP1A cohort).",
    ]

    with io.open(SCHEMA_PATH, "w", encoding="utf-8", newline="\n") as handle:
        handle.write("window.SCHEMA_DATA = ")
        handle.write(json.dumps(data, ensure_ascii=False, separators=(",", ":")))
        handle.write(";\n")

    print("wrote", SCHEMA_PATH)
    print("tables", len(tables), "relationships", len(rels), "sql assets", len(assets))
    print("relationship evidence", dict(sorted(evidence_counts.items())))


if __name__ == "__main__":
    main()
