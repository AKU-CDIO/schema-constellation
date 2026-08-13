# -*- coding: utf-8 -*-
from playwright.sync_api import sync_playwright

with sync_playwright() as p:
    browser = p.chromium.launch()
    page = browser.new_page()
    bad = set()
    page.on("response", lambda r: bad.add(r.url) if r.status >= 400 else None)
    page.goto("http://127.0.0.1:8123/explorer.html")
    page.wait_for_timeout(1200)

    page.evaluate("location.hash='#tbl=AdmVisits'")
    page.wait_for_timeout(400)
    assert not page.evaluate("document.querySelector('#detail').classList.contains('hidden')"), "panel should be open"
    assert page.locator("#detail .detail-close").count() == 1, "close button should exist"

    page.locator("#detail .detail-close").click()
    page.wait_for_timeout(300)
    assert page.evaluate("document.querySelector('#detail').classList.contains('hidden')"), "click should close panel"

    page.evaluate("location.hash='#tbl=AdmVisits'")
    page.wait_for_timeout(400)
    page.keyboard.press("Escape")
    page.wait_for_timeout(300)
    assert page.evaluate("document.querySelector('#detail').classList.contains('hidden')"), "Escape should close panel"

    page.evaluate("location.hash='#tbl=AdmVisits'")
    page.wait_for_timeout(400)
    page.mouse.click(800, 470)
    page.wait_for_timeout(300)
    assert page.evaluate("document.querySelector('#detail').classList.contains('hidden')"), "click outside should close panel"

    for url in sorted(bad):
        print("HTTP>=400:", url)
    assert not {u for u in bad if "/auth/session" not in u}, sorted(bad)
    browser.close()

print("PASS: detail panel close button and Escape both close the popup")
