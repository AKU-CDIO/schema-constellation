# -*- coding: utf-8 -*-
"""Import table row counts from Information_Schema_column_row_counts.csv."""
from __future__ import annotations
import csv, json, os, sys

ROOT=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT=os.path.join(ROOT,"dev","source_row_counts.json")

def main():
    if len(sys.argv)!=2:
        raise SystemExit("Pass Information_Schema_column_row_counts.csv")
    tables={}
    with open(sys.argv[1],encoding="utf-8-sig",newline="") as handle:
        for row in csv.DictReader(handle):
            key=".".join((row["TABLE_CATALOG"],row["TABLE_SCHEMA"],row["TABLE_NAME"]))
            if key in tables:
                continue
            raw=(row.get("TotalRows") or "").strip()
            rows=None if not raw or raw.upper()=="NULL" else int(float(raw.replace(",","")))
            columns=int(row.get("TotalColumns") or 0)
            quality="unknown" if rows is None else ("empty" if rows==0 else ("near-empty" if rows<1000 else "usable"))
            tables[key]={"rows":rows,"columns":columns,"quality":quality,"default_visible":quality in {"usable","unknown"}}
    with open(OUT,"w",encoding="utf-8",newline="\n") as handle:
        json.dump({"near_empty_threshold":1000,"tables":tables},handle,separators=(",",":"))
        handle.write("\n")
    print("wrote",OUT,"tables",len(tables))

if __name__=="__main__":
    main()
