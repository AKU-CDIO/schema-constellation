# -*- coding: utf-8 -*-
"""Browser gate for plan status, field-aware SQL, and relationship toggle."""
from playwright.sync_api import sync_playwright


BASE = "http://127.0.0.1:8123/"
errors = []
bad_urls = set()
with sync_playwright() as p:
    browser = p.chromium.launch()
    page = browser.new_page(viewport={"width": 1680, "height": 940})
    page.on("response", lambda r: bad_urls.add(r.url) if r.status >= 400 else None)
    page.on("pageerror", lambda err: errors.append(str(err)))

    page.goto(BASE + "sps.html")
    page.wait_for_function("document.querySelector('#spAssets').textContent === '63'", timeout=60000)
    assert page.locator(".topic-block").count() == 54
    assert page.locator("[data-proc]").count() == 63
    assert page.locator("#spN").inner_text() == "54"
    assert page.locator("#spImplemented").inner_text() == "54"
    assert page.locator("#spAssets").inner_text() == "63"
    family_sql = "\n".join(page.locator("#topic-family .sql-code").all_text_contents())
    relat_line = next(line for line in family_sql.splitlines() if "MisRelat_Main" in line)
    assert "DISTINCT PatientID" not in relat_line
    assert "[AKULiveATdb].[dbo].[MisRelat_Main]" in family_sql
    assert "IMPLEMENTED" in page.locator("#topic-surgery").inner_text().upper()

    page.goto(BASE + "explorer.html")
    page.wait_for_function("document.querySelector('#usableCount').textContent !== '—'", timeout=60000)
    assert page.locator(".node").count() == int(page.locator("#usableCount").inner_text())
    assert page.locator(".edge").count() > 0
    hidden = int(page.locator("#allLinksCount").inner_text())
    assert hidden > 0
    page.locator("#allLinks").check()
    page.wait_for_timeout(400)
    assert page.locator(".edge").count() > 0
    page.goto(BASE + "explorer.html#tbl=HimRec_Main")
    page.wait_for_timeout(700)
    assert page.locator(".rels .rel").count() > 0
    assert "evidence and confidence" in page.locator("#detail").inner_text().lower()

    ignored = ("favicon", "/auth/session")
    bad_real = [u for u in bad_urls if not any(i in u for i in ignored)]
    assert not bad_real, f"HTTP>=400: {sorted(bad_real)}"
    assert not errors, errors
    browser.close()

print("PASS: SP catalog/status, field-aware SQL, and expanded relationship UI")
