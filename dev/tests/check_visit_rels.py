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
    pg.goto("http://127.0.0.1:8123/explorer.html")
    pg.wait_for_timeout(1200)
    # detail on AbsAcct_Diagnoses should list AdmVisits rel with VisitID key
    pg.evaluate("document.querySelector('#svg g.node[data-id=\\'AbsAcct_Diagnoses\\']').dispatchEvent(new MouseEvent('click',{bubbles:true}))")
    pg.wait_for_timeout(400)
    rels = pg.evaluate("Array.from(document.querySelectorAll('#detail .rel')).map(r => r.textContent)")
    adm = [r for r in rels if "AdmVisits" in r]
    print("rel rows w/ AdmVisits:", adm[:3])
    # doc topic diagnoses: check VI edge labels present
    pg.goto("http://127.0.0.1:8123/explorer.html#topic=diagnosis")
    pg.wait_for_timeout(1200)
    labs = pg.evaluate("Array.from(document.querySelectorAll('#svg .edgelabel')).map(e => e.textContent)")
    print("edge labels in diagnosis topic:", sorted(set(labs)))
    print("console errors:", errs if errs else "none")
    pg.close()
    b.close()
