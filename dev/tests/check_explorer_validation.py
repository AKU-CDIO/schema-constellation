# -*- coding: utf-8 -*-
"""Ensure the Explorer uses the same field-aware validation generator."""
from playwright.sync_api import sync_playwright


errors = []
with sync_playwright() as p:
    browser = p.chromium.launch()
    page = browser.new_page(viewport={"width": 1680, "height": 940})
    page.on("console", lambda msg: errors.append(msg.text) if msg.type == "error" and "auth/session" not in (msg.location or {}).get("url", "") else None)
    page.on("pageerror", lambda err: errors.append(str(err)))
    page.goto("http://127.0.0.1:8123/explorer.html#topic=doc:Family%20Medical%20History")
    page.wait_for_timeout(1400)
    panel = page.locator("#detail").text_content()
    assert "IMPLEMENTED" in panel
    sql = page.locator("#detail .sqlbox pre").last.text_content()
    line = next(row for row in sql.splitlines() if "MisRelat_Main" in row)
    assert "DISTINCT PatientID" not in line
    assert "[AKULiveATdb].[dbo].[MisRelat_Main]" in sql
    assert not errors, errors
    browser.close()

print("PASS: Explorer procedure validation is field-aware")
