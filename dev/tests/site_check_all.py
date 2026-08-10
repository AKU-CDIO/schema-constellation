# -*- coding: utf-8 -*-
from playwright.sync_api import sync_playwright

pages = ["index.html", "explorer.html", "topics.html", "sql.html", "sps.html", "sp-review.html", "404.html"]
with sync_playwright() as p:
    b = p.chromium.launch()
    for pg_name in pages:
        pg = b.new_page(viewport={"width": 1680, "height": 940})
        errs = []
        pg.on("console", lambda m, e=errs: e.append(m.text) if m.type == "error" else None)
        pg.on("pageerror", lambda e, l=errs: l.append(str(e)))
        pg.goto("http://127.0.0.1:8123/" + pg_name)
        pg.wait_for_timeout(1800 if "explorer" in pg_name else 1200)
        brand = pg.evaluate("(document.querySelector('.nav .brand b, header .brand h1')||{}).innerText || ''")
        print(f"{pg_name}: brand='{brand}' errs={len(errs)}")
        for e in errs[:6]:
            print("   ", e[:160])
        pg.close()
    b.close()
