# -*- coding: utf-8 -*-
"""Browser gate for the complete SP Review page."""
from playwright.sync_api import sync_playwright


errors = []
with sync_playwright() as p:
    browser = p.chromium.launch()
    page = browser.new_page(viewport={"width": 1680, "height": 940})
    bad_urls = set()
    page.on("response", lambda r: bad_urls.add(r.url) if r.status >= 400 else None)
    page.on("pageerror", lambda err: errors.append(str(err)))
    page.goto("http://127.0.0.1:8123/sp-review.html")
    page.wait_for_function("document.querySelectorAll('.asset-card').length === 63", timeout=60000)

    assert page.locator("[data-topic]").count() == 54
    assert page.locator(".asset-card").count() == 63
    assert page.locator(".priority-card").count() >= 8
    assert page.locator(".priority-card:has-text('Apply SP review suggestions')").count() == 1
    assert page.locator(".review-card:has-text('SP review suggestions')").count() == 54
    assert page.locator(".review-card:has-text('Validation findings')").count() == 0
    assert page.locator(".review-card:has-text('Recommended improvements')").count() == 0
    assert page.locator("[data-check]").count() == 31
    assert page.locator("#review-encounter [data-check=\"4\"]").count() == 1
    assert page.locator("#review-encounter").inner_text().count("Check 4") == 1
    vitals = page.locator("#review-vitals").inner_text()
    assert "Observation time has no dedicated source column" in vitals
    assert "Topic source contract:" in vitals
    assert "Not read by SQL: EmrGrowthChartAudit_DataPoints, EmrGrowthChartAudit_Main, EmrGrowthSet_Main" in vitals
    assert "SQL-only supporting sources: AdmVisits" in vitals
    assert page.locator("#rvTotal").inner_text() == "54"
    assert page.locator("#rvImplemented").inner_text() == "54"
    assert page.locator("#rvShared").inner_text() == "0"
    assert page.locator("#rvBlueprint").inner_text() == "0"
    assert page.locator("#rvGap").inner_text() == "0"
    assert page.locator("#rvEvent").inner_text() == "48"

    page.locator("#rvStatus").select_option("source-gap")
    assert page.locator('[data-topic]:visible').count() == 0
    page.locator("#rvStatus").select_option("")
    page.locator("#rvEventFilter").select_option("no")
    assert page.locator('[data-topic]:visible').count() == 6
    page.locator("#rvEventFilter").select_option("")

    page.locator("#rvSearch").fill("Surgical Cases")
    assert page.locator('[data-topic]:visible').count() == 1
    surgery = page.locator("#review-surgery")
    assert "IMPLEMENTED" in surgery.inner_text().upper()
    assert "EVENT-BASED: YES" in surgery.inner_text().upper()
    page.evaluate("document.querySelector('#review-surgery details').setAttribute('open', '')")
    assert "Output health" in surgery.locator("pre").inner_text()

    page.locator("#rvSearch").fill("")
    diagnosis = page.locator("#review-diagnosis")
    assert "HYBRID" in diagnosis.inner_text().upper()
    assert "usp_Build_FCAP1A_Diagnoses_Extended" in diagnosis.inner_text()
    assert "Not read by SQL" in diagnosis.inner_text()
    assert "Output validation query" in diagnosis.inner_text()

    assert page.locator('a[href="sps.html"]').count() > 0
    ignored = ("favicon", "/auth/session")
    bad_real = [u for u in bad_urls if not any(i in u for i in ignored)]
    assert not bad_real, f"HTTP>=400: {sorted(bad_real)}"
    assert not errors, errors
    browser.close()

print("PASS: complete SP Review renders 54 searchable topic contracts and 63 asset audits")
