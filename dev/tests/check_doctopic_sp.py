# -*- coding: utf-8 -*-
from playwright.sync_api import sync_playwright
errs = []
with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1680, "height": 940})
    pg.on("console", lambda m: errs.append(m.text) if m.type == "error" else None)
    pg.on("pageerror", lambda e: errs.append(str(e)))
    pg.goto("http://127.0.0.1:8123/explorer.html")
    pg.wait_for_timeout(1200)
    # click the "Diagnosis" doc topic in the sidebar
    pg.evaluate("Array.from(document.querySelectorAll('#doctopics .dtopic')).find(r => r.textContent.includes('Diagnosis')).click()")
    pg.wait_for_timeout(400)
    h = pg.evaluate("location.hash")
    print("hash:", h)
    print("has SP Generation Plan:", pg.evaluate("!!Array.from(document.querySelectorAll('#detail h3')).find(h => h.textContent.includes('SP Generation Plan'))"))
    print("SP chip:", pg.evaluate("Array.from(document.querySelectorAll('#detail .chip')).map(c => c.textContent).find(x => x.includes('sp_FCAP1A'))"))
    print("has quick validation sql:", pg.evaluate("Array.from(document.querySelectorAll('#detail .sec h3')).some(h => h.textContent.includes('Quick validation'))"))
    sql = pg.evaluate("Array.from(document.querySelectorAll('#detail .sqlbox pre')).map(p => p.textContent).find(x => x.includes('sp_FCAP1A_Diagnoses')) || ''")
    print("diag SP sql len:", len(sql), "| has VISIT GRAIN:", 'VISIT GRAIN' in sql, "| has MissingVisit:", 'MissingVisit' in sql)
    print("visit spine rows:", pg.evaluate("Array.from(document.querySelectorAll('#detail .sec h3')).filter(h => h.textContent.includes('Visit / encounter')).length"))
    # sp table chips count + clickable
    chips = pg.evaluate("document.querySelectorAll('#detail [data-sptbl]').length")
    print("SP source chips:", chips)
    # click a chip -> table detail opens
    pg.evaluate("document.querySelector('#detail [data-sptbl]').click()")
    pg.wait_for_timeout(300)
    print("after chip click hash:", pg.evaluate("location.hash"), "| mode:", pg.evaluate("state.mode"))
    # open a doc topic with no SP mapping (CT) -> note shown
    pg.evaluate("location.hash='#topic=doc:'+encodeURIComponent('CT')")
    pg.wait_for_timeout(400)
    print("CT has note:", pg.evaluate("!!Array.from(document.querySelectorAll('#detail .notable')).find(n => n.textContent.includes('No FCAP1A SP proposal'))"))
    # back from CT
    pg.go_back(); pg.wait_for_timeout(400)
    print("back hash:", pg.evaluate("location.hash"), "| detail hidden:", pg.evaluate("document.querySelector('#detail').classList.contains('hidden')"))
    print("console errors:", errs if errs else "none")
    pg.close()
    b.close()
