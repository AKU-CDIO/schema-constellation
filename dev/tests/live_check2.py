# -*- coding: utf-8 -*-
from playwright.sync_api import sync_playwright
BASE = "https://storage.googleapis.com/cdio-migration-schema-constellation/"
errs = []
with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1680, "height": 940})
    pg.on("console", lambda m: errs.append(m.text) if m.type == "error" else None)
    pg.on("pageerror", lambda e: errs.append(str(e)))
    # explorer
    pg.goto(BASE + "explorer.html#topic=diagnosis")
    pg.wait_for_timeout(2500)
    print("live explorer nodes:", pg.evaluate("state.count"))
    print("  mode:", pg.evaluate("state.mode"))
    pg.evaluate("document.querySelector('#svg g.node[data-id=\\'AbsAcct_Diagnoses\\']').dispatchEvent(new MouseEvent('click',{bubbles:true}))")
    pg.wait_for_timeout(400)
    print("  detail opens, hash:", pg.evaluate("location.hash"))
    pg.go_back(); pg.wait_for_timeout(500)
    print("  back -> detail hidden:", pg.evaluate("document.querySelector('#detail').classList.contains('hidden')"), "| hash:", pg.evaluate("location.hash"))
    # doc topic SP plan
    pg.goto(BASE + "explorer.html")
    pg.wait_for_timeout(2000)
    pg.evaluate("Array.from(document.querySelectorAll('#doctopics .dtopic')).find(r => r.textContent.includes('Diagnosis')).click()")
    pg.wait_for_timeout(400)
    print("live doc-topic SP plan:", pg.evaluate("!!Array.from(document.querySelectorAll('#detail h3')).find(h => h.textContent.includes('SP Generation Plan'))"), "| chips:", pg.evaluate("document.querySelectorAll('#detail [data-sptbl]').length"))
    # sps
    pg.goto(BASE + "sps.html")
    pg.wait_for_timeout(2500)
    print("live sps blocks:", pg.evaluate("document.querySelectorAll('.topic-block').length"))
    print("  stats:", pg.evaluate("Array.from(document.querySelectorAll('#spStats .stat')).map(s => s.textContent.replace(/\\s+/g,' ').trim()).join(' | ')"))
    print("  visit spine sections:", pg.evaluate("Array.from(document.querySelectorAll('.sp-col h4')).filter(h => h.textContent.includes('spine')).length"))
    print("console errors:", errs if errs else "none")
    pg.close()
    b.close()
