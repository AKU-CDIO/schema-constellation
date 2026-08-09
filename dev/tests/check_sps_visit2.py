# -*- coding: utf-8 -*-
from playwright.sync_api import sync_playwright
errs = []
with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1680, "height": 940})
    pg.on("console", lambda m: errs.append(m.text) if m.type == "error" else None)
    pg.on("pageerror", lambda e: errs.append(str(e)))
    pg.goto("http://127.0.0.1:8123/sps.html")
    pg.wait_for_timeout(1500)
    pg.evaluate("document.querySelector('.sql-card').setAttribute('open','')")
    pg.wait_for_timeout(200)
    print("details opens:", pg.evaluate("document.querySelectorAll('.sql-card[open]').length") >= 1)
    # copy button (clipboard needs permission; just ensure handler attached)
    print("copy buttons:", pg.evaluate("document.querySelectorAll('.copy-btn').length"))
    print("console errors:", errs if errs else "none")
    pg.close()
    b.close()
