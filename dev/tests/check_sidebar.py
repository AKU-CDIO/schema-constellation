# -*- coding: utf-8 -*-
from playwright.sync_api import sync_playwright
errs = []
with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1680, "height": 940})
    pg.on("console", lambda m: errs.append(m.text) if m.type == "error" else None)
    pg.on("pageerror", lambda e: errs.append(str(e)))
    pg.goto("http://127.0.0.1:8123/explorer.html")
    pg.wait_for_timeout(1500)
    print("side labels:", pg.evaluate("Array.from(document.querySelectorAll('.side-label')).map(s => s.textContent)"))
    print("topic items:", pg.evaluate("document.querySelectorAll('#topiclist .topic').length"))
    print("doctopics items:", pg.evaluate("document.querySelectorAll('#doctopics .dtopic').length"))
    print("questionlist present:", pg.evaluate("!!document.querySelector('#questionlist')"))
    print("catalog present:", pg.evaluate("!!document.querySelector('#catalog')"))
    # click a curated topic -> topic view
    pg.evaluate("document.querySelector('#topiclist .topic').click()")
    pg.wait_for_timeout(400)
    print("topic click mode:", pg.evaluate("state.mode"), "| hash:", pg.evaluate("location.hash"))
    # click a doc topic -> drill-down panel
    pg.evaluate("Array.from(document.querySelectorAll('#doctopics .dtopic')).find(r => r.textContent.includes('Diagnosis')).click()")
    pg.wait_for_timeout(400)
    print("doc click hash:", pg.evaluate("location.hash"), "| has SP plan:", pg.evaluate("Array.from(document.querySelectorAll('#detail h3')).some(h => h.textContent.includes('SP Generation Plan'))"))
    # Back crumb closes panel now
    pg.evaluate("document.querySelector('#detail [data-crumb]').click()")
    pg.wait_for_timeout(400)
    print("after back crumb: mode:", pg.evaluate("state.mode"), "| detail hidden:", pg.evaluate("document.querySelector('#detail').classList.contains('hidden')"))
    print("console errors:", errs if errs else "none")
    pg.close()
    b.close()
