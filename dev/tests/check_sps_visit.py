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
    n = pg.evaluate("document.querySelectorAll('.topic-block').length")
    print("topic blocks:", n)
    print("stats:", pg.evaluate("Array.from(document.querySelectorAll('#spStats .stat')).map(s => s.textContent.replace(/\\s+/g,' ').trim())"))
    spines = pg.evaluate("Array.from(document.querySelectorAll('.sp-col h4')).map(h => h.textContent)")
    print("spine headings:", [s for s in spines if 'spine' in s])
    visChips = pg.evaluate("document.querySelectorAll('.sp-card .chip').length")
    print("total zone chips:", visChips)
    visitChips = pg.evaluate("Array.from(document.querySelectorAll('.sp-card .chip')).filter(c => c.textContent === 'VisitID').length")
    print("VisitID chips on cards:", visitChips)
    d = pg.evaluate("document.querySelector('#sp-diagnosis').textContent")
    print("diagnosis block has AdmVisits -> AbsAcct_Diagnoses:", 'AbsAcct_Diagnoses' in d and 'SourceID + VisitID' in d)
    # validation SQL contains visit grain + visits contract
    sql = pg.evaluate("document.querySelector('#sp-diagnosis details pre')?.textContent || ''")
    print("diag sql has VISIT GRAIN:", 'VISIT GRAIN' in sql, "| has Visits contract:", 'COUNT(DISTINCT VisitID)' in sql)
    # cross-sp visit linkage card
    x = pg.evaluate("document.querySelector('#xsp').textContent")
    print("xsp has Visit linkage:", 'Visit linkage' in x, "| has Encounters_Extended:", 'tbl_FCAP1A_Encounters_Extended' in x)
    # open a details block, ensure renders
    pg.evaluate("document.querySelector('details.sql-card').setAttribute('open','')")
    pg.wait_for_timeout(200)
    print("details open works:", pg.evaluate("!!document.querySelector('details.sql-card[open]')"))
    print("console errors:", errs if errs else "none")
    pg.close()
    b.close()
