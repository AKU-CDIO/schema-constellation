# -*- coding: utf-8 -*-
import io, sys
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8")
from playwright.sync_api import sync_playwright
errs = []
with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1680, "height": 940})
    pg.on("console", lambda m: errs.append(m.text) if m.type == "error" else None)
    pg.on("pageerror", lambda e: errs.append(str(e)))
    pg.goto("https://storage.googleapis.com/cdio-migration-schema-constellation/sps.html")
    pg.wait_for_timeout(2500)
    pg.wait_for_selector("#sp-diagnosis .trace-btn", timeout=10000, state="attached")
    pg.evaluate("const ds = document.querySelectorAll('#sp-diagnosis details.sql-card'); const t = ds[1] || ds[ds.length-1]; if (t) t.setAttribute('open','')")
    pg.fill("#sp-diagnosis .trace-pid", "P12345")
    pg.evaluate("document.querySelector('#sp-diagnosis .trace-btn').click()")
    pg.wait_for_timeout(400)
    code = pg.evaluate("document.querySelector('#sp-diagnosis .trace-code').textContent")
    print("trace sql len:", len(code))
    print("has TRACE ONE PATIENT:", "TRACE ONE PATIENT : P12345" in code)
    print("has OutRows:", "SELECT COUNT(*) AS OutRows" in code)
    print("has JoinRows & EXPECT:", "JoinRows" in code and "EXPECT:" in code)
    cb = pg.evaluate("document.querySelector('#sp-diagnosis .trace-copy').getAttribute('data-sql')")
    print("copy data-sql set:", len(cb) > 100)
    print("console errors:", errs if errs else "none")
    pg.close()
    b.close()
