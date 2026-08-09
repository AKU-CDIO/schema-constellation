# -*- coding: utf-8 -*-
from playwright.sync_api import sync_playwright
errs = []
with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1680, "height": 940})
    pg.on("console", lambda m: errs.append(m.text) if m.type == "error" else None)
    pg.on("pageerror", lambda e: errs.append(str(e)))
    pg.goto("http://127.0.0.1:8123/index.html")
    pg.wait_for_timeout(1600)
    print("index stats:", pg.evaluate("['stTables','stSrc','stTopics','stRels','stVisit','stCatalog'].map(i => document.getElementById(i).textContent).join('/')"))
    print("index steps:", pg.evaluate("document.querySelectorAll('.path .step').length"))
    print("index mini labels:", pg.evaluate("Array.from(document.querySelectorAll('.mlabel')).map(s => s.textContent).join(' | ')"))
    pg.goto("http://127.0.0.1:8123/topics.html")
    pg.wait_for_timeout(1600)
    print("topics blocks:", pg.evaluate("document.querySelectorAll('#topics .topic-block').length"))
    print("topics stats:", pg.evaluate("['tpN','tpTbls','tpRels','tpVisit','tpKeys'].map(i => (document.getElementById(i)||{}).textContent||'-').join('/')"))
    print("topics spine headings:", pg.evaluate("Array.from(document.querySelectorAll('h4')).filter(h => h.textContent.includes('spine')).length"))
    print("topics sql-cards:", pg.evaluate("document.querySelectorAll('#topics .sql-card').length"))
    print("topics copy btns:", pg.evaluate("document.querySelectorAll('#topics .copy-btn').length"))
    print("topics first explore link:", pg.evaluate("(() => { const a = document.querySelector('#topics a[href*=\"explorer.html#topic=\"]'); return a ? a.getAttribute('href') : null })()"))
    print("console errors:", errs if errs else "none")
    pg.close()
    b.close()
