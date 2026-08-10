# Schema Constellation · AKU CDIO MAYO

An interactive visual documentation site for the AKU CDIO **Meditech EMR** analysis schema built for the **MAYO cohort study**. It maps the Meditech source tables, the join keys (SourceID + PatientID / SourceID + VisitID), the visit/encounter spine, and the SQL each `FCAP1A` build stored procedure uses to reconcile its output.

Live: `https://storage.googleapis.com/cdio-migration-schema-constellation/index.html`

## Pages

| File | Purpose |
|------|---------|
| `index.html` | Landing page · constellation overview, stats, join-key legend, link to each data topic. |
| `topics.html` | Data Topics · each clinical domain as a block with source tables, join plan, visit spine, validation SQL, and a **trace one patient** generator. Deep link: `topics.html#<topic-id>`. |
| `explorer.html` | Interactive constellation · click a table to see neighbours, join keys and relationships. Sidebar offers a **VisitID-only** filter. Deep link: `explorer.html?table=<name>`. |
| `sql.html` | SQL cookbook · reusable query patterns. |
| `sps.html` | SP workspace · per-topic validation SQL generated from the FCAP1A stored procedures. Search + deep link: `sps.html#<topic-id>`. |
| `404.html` | Missing-route fallback. |
| `assets/site.css` | Shared styles (also inline `<style>` blocks per page). |
| `data/schema.js` | `window.SCHEMA_DATA` — tables, relationships, topics. |

## Serve locally

```powershell
cd schema-constellation
python -m http.server 8123 --bind 127.0.0.1
# open http://127.0.0.1:8123/index.html
```

## Test

Playwright regression scripts live in `dev/tests/`. They expect the local server on `127.0.0.1:8123`:

```powershell
cd schema-constellation\dev\tests
python check_index_topics.py     # landing + topics + back links
python check_explorer_keys.py    # explorer join-key colours + VisitID filter
python check_sps_visit.py        # SP workspace visit keys
python check_sps_trace.py        # SP trace SQL
python check_topics_trace_sps.py # topics trace + deep links + sps search
python layout_check2.py          # page layout regression
python check_back.py             # back/close navigation
python check_sidebar.py          # explorer sidebar
python check_visit_rels.py       # visit relationships
python func_check_new.py         # functional drill-down
python func_check_doc.py         # document topic
python check_doctopic_sp.py      # document topic in SP workspace
python site_check_all.py         # smoke all pages
```

Live (post-deploy) checks: `live_check2.py`, `live_check3.py`, `live_trace_check2.py` run against the GCS URLs.

## Deploy

The site is static and served from Google Cloud Storage. Deploy with no-cache headers so every push is immediately visible:

```powershell
gsutil -m -h "Cache-Control: public, max-age=0, must-revalidate" cp `
  -r index.html explorer.html topics.html sql.html sps.html 404.html assets data `
  gs://cdio-migration-schema-constellation
```

The fcap1a stored-procedure sources used for SP semantics are in `dev/fcap1a_utf8/`.

## Notes

- Schema generated from the AKU Meditech schema dump + FCAP1A build stored procedures.
- Analysis window: 2022-11-05 → 2026-06-14.
- Join-key convention: blue = PatientID grain (`SourceID + PatientID`), amber = VisitID grain (`SourceID + VisitID`).

## Relationship and procedure completion

- `dev/finalize_schema.py` preserves the curated graph and adds auditable SQL lineage, schema-FK, table-family, and key-grain links. Every relationship records `kind`, `evidence`, `confidence`, and whether it belongs in the default graph.
- The explorer keeps the 101 hand-curated source joins readable by default; **All documented links** reveals the derived relationship layer.
- `data/phases.js` distinguishes checked-in **implemented** procedures from **blueprints** and carries the full SQL asset catalog.
- The source named `info_schema.csv` contains XLSX workbook bytes (17,094 tables / 143,082 columns); do not parse it as comma-separated text.
- Run `python dev/finalize_schema.py` before `python dev/build_phases.py` whenever SQL assets or the schema catalog change.
