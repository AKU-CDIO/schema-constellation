# Schema Constellation · AKU CDIO MAYO

An interactive visual documentation site for the AKU CDIO **Meditech EMR** analysis schema built for the **MAYO cohort study**. It maps the Meditech source tables, the join keys (SourceID + PatientID / SourceID + VisitID), the visit/encounter spine, and the SQL each `FCAP1A` build stored procedure uses to reconcile its output.

Live: `https://schema-constellation-864230826730.us-central1.run.app/index.html`

## Pages

| File | Purpose |
|------|---------|
| `index.html` | Concise AKU-CDIO Meditech welcome, platform totals, and four-step topic-to-SP flow. |
| `topics.html` | Data Topics grouped into the five delivery phases. |
| `explorer.html` | Interactive constellation with composite-key links, topic assembly SQL, exact checked-in SP source, and validation SQL. Deep link: `explorer.html#topic=doc:<topic-name>`. |
| `sql.html` | Reusable query patterns and clinical examples. |
| `mapping.html` | Chronological MEDITECH-to-AKU mapping workflow, official reference, INFORMATION_SCHEMA substitutions, and relationship gate. |
| `sps.html` | Per-topic SP workspace and trace validation. |
| `sp-review.html` | Complete 54-topic SP quality, event model, evidence, gap, and recommendation review. |
| `404.html` | Missing-route fallback. |
| `data/schema.js` | Tables, relationships, topics, row counts, and evidence metadata. |
| `data/phases.js` | The 54 implemented topic contracts and 63 SQL assets. |
| `data/sp_source.js` | Generated exact SQL, procedure-confirmed topic links, and read-only assembly queries. |

## Serve locally

Use the production server locally so authentication-session and security behavior are exercised:

```powershell
cd schema-constellation
$env:PORT = "8123"
node server.js
# open http://127.0.0.1:8123/
```

## Test

The production contract tests cover schema integrity, row-count quality bands, all 54 topic/SP contracts, all 63 SQL assets, navigation, account UI, mapping evidence, and server authentication:

```powershell
python dev/tests/check_account_ui.py
python dev/tests/check_auth_static.py
python dev/tests/check_data_integrity.py
python dev/tests/check_remaining_topics.py
python dev/tests/check_sp_review_data.py
python dev/tests/check_sql_static.py
python dev/tests/check_production_readiness.py
python dev/tests/check_topic_connections.py
node dev/tests/check_auth_runtime.js
```

Playwright browser checks in `dev/tests/` exercise the local site on `127.0.0.1:8123`.

## Deploy

Production is a private Google Cloud Run service protected by Identity-Aware Proxy. Deploy the exact validated repository root:

```powershell
gcloud run deploy schema-constellation --source . --project cdiorg-migration --region us-central1 --quiet
```

Keep the legacy GCS bucket private; a public object URL would bypass the application and IAP controls. The application accepts IAP identities only from `@gcp.cdio.aku.edu` in Cloud Run.

The fcap1a stored-procedure sources used for SP semantics are in `dev/fcap1a_utf8/`.

## Notes

- Schema generated from the AKU Meditech schema dump + FCAP1A build stored procedures.
- The supplied AKU catalog contains no `SysDrTables` or `SysDrColumns`. `mapping.html` therefore supports structural discovery and candidate relationships, but does not claim official Keylevel, SortKey, feeder-application, or NPR DPM/segment/element lineage.
- Analysis window: 2022-11-05 → 2026-06-14.
- Join-key convention: blue = PatientID grain (`SourceID + PatientID`), amber = VisitID grain (`SourceID + VisitID`).

## Relationship and procedure completion

- `dev/finalize_schema.py` preserves the curated graph and adds auditable SQL lineage, schema-FK, table-family, and key-grain links. Every relationship records `kind`, `evidence`, `confidence`, and whether it belongs in the default graph.
- The explorer keeps the 101 hand-curated source joins readable by default; **All documented links** reveals the derived relationship layer.
- `data/phases.js` distinguishes checked-in **implemented** procedures from **blueprints** and carries the full SQL asset catalog.
- The source named `info_schema.csv` contains XLSX workbook bytes (17,094 tables / 143,082 columns); do not parse it as comma-separated text.
- Run `python dev/finalize_schema.py` before `python dev/build_phases.py` whenever SQL assets or the schema catalog change.
- Run `python dev/build_sp_source.py` after any topic, relationship, or SQL change; it emits the Explorer's full SP source, procedure-confirmed joins, evidence-labelled fallback associations, and read-only assembly queries.

## Complete SP quality review

- `dev/build_sp_review.py` audits all checked-in SQL assets and emits `data/sp_review.js`.
- `sp-review.html` provides a searchable contract for all 54 data topics: procedure/output name, description, implementation status, data grain, event-based classification, canonical time, planned-vs-SQL sources, findings, recommendations, and an executable validation or source-discovery query.
- Regenerate it after schema, topic, or SQL changes with `python dev/build_sp_review.py`.


## Authentication and secure hosting

The production platform runs on Google Cloud Run with Identity-Aware Proxy (IAP) enabled directly on the service. IAP handles Google sign-in and GCP IAM controls which users or groups can open the platform. The application rejects Cloud Run requests that do not carry the authenticated IAP identity headers.

- server.js serves the static platform, exposes the signed-in account at /auth/session, and applies security headers.
- assets/account.js displays the active Google account and provides profile, security, and platform sign-out actions.
- Dockerfile packages the site for Cloud Run without third-party runtime dependencies.
- Keep the legacy GCS bucket private after the Cloud Run service is verified; otherwise its object URLs bypass IAP.
