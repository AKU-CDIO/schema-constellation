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
    base = "https://storage.googleapis.com/cdio-migration-schema-constellation/"
    pg.goto(base + "index.html")
    pg.wait_for_timeout(1800)
    print("index stats:", pg.evaluate("['stTables','stSrc','stTopics','stRels','stVisit','stCatalog'].map(i => document.getElementById(i).textContent).join('/')"))
    print("index steps:", pg.evaluate("document.querySelectorAll('.path .step').length"))
    pg.goto(base + "topics.html")
    pg.wait_for_timeout(1800)
    print("topics blocks:", pg.evaluate("document.querySelectorAll('#topics .topic-block').length"))
    print("topics stats:", pg.evaluate("['tpN','tpTbls','tpRels','tpVisit','tpKeys'].map(i => (document.getElementById(i)||{}).textContent||'-').join('/')"))
    print("topics sql-cards:", pg.evaluate("document.querySelectorAll('#topics .sql-card').length"))
    print("topics spine headings:", pg.evaluate("Array.from(document.querySelectorAll('h4')).filter(h => h.textContent.includes('spine')).length"))
    print("topics explore link:", pg.evaluate("(() => { const a = document.querySelector('#topics a[href*=\"explorer.html#topic=\"]'); return a ? a.getAttribute('href') : null })()"))
    pg.goto(base + "explorer.html")
    pg.wait_for_timeout(1500)
    print("live sidebar labels:", pg.evaluate("Array.from(document.querySelectorAll('.side-label')).map(s => s.textContent)"))
    print("live doctopics:", pg.evaluate("document.querySelectorAll('#doctopics .dtopic').length"))
    print("console errors:", errs if errs else "none")
    pg.close()
    b.close()
