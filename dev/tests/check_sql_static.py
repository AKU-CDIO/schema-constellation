# -*- coding: utf-8 -*-
"""Static SQL gate: created indexes may reference only created table columns."""
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SQL_DIR = ROOT / "dev" / "fcap1a_utf8"


def body_at(text, start):
    depth = 0
    for index in range(start, len(text)):
        if text[index] == "(":
            depth += 1
        elif text[index] == ")":
            depth -= 1
            if depth == 0:
                return text[start + 1:index]
    return ""


errors = []
for path in sorted(SQL_DIR.glob("*.sql")):
    text = path.read_text(encoding="utf-8-sig", errors="replace")
    created = {}
    for match in re.finditer(r"CREATE\s+TABLE\s+(?:\[?dbo\]?\.)?\[?([A-Za-z0-9_]+)\]?\s*\(", text, re.I):
        body = body_at(text, match.end() - 1)
        columns = set(re.findall(r"(?:^|,)\s*\[?([A-Za-z0-9_]+)\]?\s+[A-Za-z][A-Za-z0-9_]*(?:\s*\([^)]*\))?", body, re.I | re.M))
        created[match.group(1).lower()] = {col.lower() for col in columns if col.upper() not in {"CONSTRAINT", "PRIMARY", "UNIQUE", "FOREIGN", "CHECK"}}
    for match in re.finditer(r"CREATE\s+(?:UNIQUE\s+)?(?:NONCLUSTERED\s+|CLUSTERED\s+)?INDEX\s+\[?([A-Za-z0-9_]+)\]?\s+ON\s+(?:\[?dbo\]?\.)?\[?([A-Za-z0-9_]+)\]?\s*\(", text, re.I):
        index_name, table = match.group(1), match.group(2)
        cols = [c.lower() for c in re.findall(r"\[?([A-Za-z0-9_]+)\]?", body_at(text, match.end() - 1)) if c.upper() not in {"ASC", "DESC"}]
        known = created.get(table.lower())
        if known is None:
            continue
        missing = [col for col in cols if col not in known]
        if missing:
            errors.append((path.name, index_name, table, missing))

assert not errors, errors
assert len(list(SQL_DIR.glob("*.sql"))) == 63
print("PASS: 63 SQL assets; all CREATE INDEX columns exist on their created tables")
