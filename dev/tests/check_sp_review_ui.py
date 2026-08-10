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
    page.wait_for_timeout(1500)

    assert page.locator("[data-topic]").count() == 54
    assert page.locator(".asset-card").count() == 31
    assert page.locator(".priority-card").count() >= 8
    assert page.locator("#rvTotal").inner_text() == "54"
    assert page.locator("#rvImplemented").inner_text() == "22"
    assert page.locator("#rvShared").inner_text() == "4"
    assert page.locator("#rvBlueprint").inner_text() == "4"
    assert page.locator("#rvGap").inner_text() == "24"
    assert page.locator("#rvEvent").inner_text() == "48"

    page.locator("#rvStatus").select_option("source-gap")
    assert page.locator('[data-topic]:visible').count() == 24
    page.locator("#rvStatus").select_option("")
    page.locator("#rvEventFilter").select_option("no")
    assert page.locator('[data-topic]:visible').count() == 6
    page.locator("#rvEventFilter").select_option("")

    page.locator("#rvSearch").fill("Surgical Cases")
    assert page.locator('[data-topic]:visible').count() == 1
    surgery = page.locator("#review-surgery")
    assert "BLUEPRINT" in surgery.inner_text().upper()
    assert "EVENT-BASED: YES" in surgery.inner_text().upper()
    page.evaluate("document.querySelector('#review-surgery details').setAttribute('open', '')")
    assert "Source readiness" in surgery.locator("pre").inner_text()

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

print("PASS: complete SP Review renders 54 searchable topic contracts and 31 asset audits")
