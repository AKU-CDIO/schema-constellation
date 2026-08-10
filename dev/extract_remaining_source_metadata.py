# -*- coding: utf-8 -*-
"""Extract the audited remaining-topic source subset from the full catalog.

Usage: python dev/extract_remaining_source_metadata.py path/to/catalog.json
"""
from __future__ import annotations

import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "dev", "remaining_source_metadata.json")

SOURCE_TABLES = [
    "AmbPatCm_PregnancyData", "AmbPatCm_PregnancyMain",
    "AmbPatCm_PregnancyNonVisitLog", "AmbPatCm_PregnancyVisitLog",
    "CmgDevices_DevicePatHistory", "CwsAppt_AuditTrail", "CwsAppt_Main_ApptComments",
    "CwsAppt_Participants", "CwsAppt_Resources", "EmrParam_AmbCanRegSocHis",
    "EmrParam_CcdFacilityGroups", "EmrParam_CcdSocHistoryQrys",
    "EmrParam_PhsSocHistoryQrys", "MisQry_Main", "PcsMarAct_BagInfusionLastDoc",
    "PcsMarAct_MarActivityTitr", "PcsMarAct_MarLastDocumented",
    "PcsMarAct_MarLastTitration", "PcsMarAct_MarMeds", "PcsMarAct_MarRxs",
    "SurCase_ActualProcs",
    "SurCase_ActualProcSurgTimes", "SurCase_Implant",
]

def main():
    if len(sys.argv) != 2:
        raise SystemExit("Pass the extracted full-catalog JSON path.")
    with open(sys.argv[1], encoding="utf-8") as handle:
        catalog = json.load(handle)
    by_name = {entry["table"]: entry for entry in catalog.values()}
    missing = [name for name in SOURCE_TABLES if name not in by_name]
    if missing:
        raise SystemExit("Missing catalog tables: " + ", ".join(missing))
    output = {}
    for name in SOURCE_TABLES:
        source = by_name[name]
        cols = []
        for col in source["columns"]:
            length = col.get("length")
            if not isinstance(length, int):
                length = None
            cols.append({"n": col["name"], "t": col["type"], "len": length,
                         "nn": str(col.get("nullable", "YES")).upper() == "NO", "fk": None})
        output[name] = {
            "name": name, "label": name.replace("_", " "),
            "desc": "Audited Meditech source for the remaining FCAP1A topic procedures.",
            "role": "source", "topic": "remaining", "zone": "source", "pk": [],
            "cols": cols, "db": source["database"], "dbs": [source["database"]],
        }
    with open(OUT, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(output, handle, ensure_ascii=False, separators=(",", ":"))
        handle.write("\n")
    print("wrote", OUT, "tables", len(output))

if __name__ == "__main__":
    main()
