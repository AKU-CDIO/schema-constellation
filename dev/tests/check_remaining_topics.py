import json, re
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
def load(path):
    text=(ROOT/path).read_text(encoding="utf-8")
    return json.loads(re.search(r"=\s*(\{.*\});",text,re.S).group(1))

schema=load(Path("data/schema.js"))
review=load(Path("data/sp_review.js"))
assert schema["meta"]["row_count_model"]["near_empty_threshold"]==1000
assert len(review["topics"])==54
assert review["summary"]["status"]=={"implemented":54}
new=[topic for topic in review["topics"] if topic.get("author")=="test"]
assert len(new)==32,len(new)
assert all(not topic["missing_sources"] for topic in new)
assert schema["tables"]["EmrPatSum_GenResults"]["row_count"]==0
assert schema["tables"]["EmrPatSum_GenResults"]["default_visible"] is False
assert schema["tables"]["CwsAppt_Main"]["default_visible"] is True
assert schema["tables"]["CwsAppt_Main_ApptComments"]["default_visible"] is False
html=(ROOT/"explorer.html").read_text(encoding="utf-8")
assert 'id="usableOnly" checked' in html and "isPopulated" in html
print("remaining procedures, author, evidence, and row-count gate: ok")
