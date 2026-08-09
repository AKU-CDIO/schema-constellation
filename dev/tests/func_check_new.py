# -*- coding: utf-8 -*-
from playwright.sync_api import sync_playwright

URL = "http://127.0.0.1:8123/explorer.html"
out = []
with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1680, "height": 940})
    errs = []
    pg.on("console", lambda m: errs.append((m.type, m.text)))
    pg.on("pageerror", lambda e: errs.append(("pageerror", str(e))))
    pg.goto(URL)
    pg.wait_for_timeout(1500)

    # topic drill
    pg.locator(".topic").nth(1).click()
    pg.wait_for_timeout(300)
    out.append(("topic", pg.locator(".node").count(), pg.evaluate("document.querySelector('.viewlabel') ? document.querySelector('.viewlabel').textContent : ''")))

    # doc topic drill-down (sidebar Data Topics -> category -> availability row)
    pg.evaluate("Array.from(document.querySelectorAll('#doctopics .catalog-group')).find(g => g.textContent.includes('Diagnoses & Problem List')).querySelector('.cg-head').click()")
    pg.evaluate("Array.from(document.querySelectorAll('#doctopics .dtopic')).find(r => r.textContent.includes('Diagnosis')).click()")
    pg.wait_for_timeout(300)
    out.append(("doc detail open", pg.evaluate("!document.getElementById('detail').classList.contains('hidden')")))
    out.append(("doc has SP plan", pg.evaluate("Array.from(document.querySelectorAll('#detail h3')).some(h => h.textContent.includes('SP Generation Plan'))")))
    out.append(("doc sp chips", pg.locator("#detail [data-sptbl]").count()))

    # table view via search
    pg.fill("#search", "EmrPat_Allergies")
    pg.wait_for_timeout(300)
    out.append(("search items", pg.locator(".searchbox .item").count()))
    pg.locator(".searchbox .item").first.click()
    pg.wait_for_timeout(300)
    out.append(("table focus mode", pg.evaluate("document.querySelector('.viewlabel') ? document.querySelector('.viewlabel').textContent : ''")))
    out.append(("detail name", pg.evaluate("document.querySelector('#detail h2').innerText")))

    # hash deep link
    pg.goto(URL + "#tbl=HimRec_Data")
    pg.wait_for_timeout(800)
    out.append(("hash tbl detail", pg.evaluate("!document.getElementById('detail').classList.contains('hidden') && document.getElementById('detail').querySelector('h2').innerText")))

    # question from detail qref section
    pg.goto(URL)
    pg.wait_for_timeout(1200)
    pg.evaluate("""(() => { const n = document.querySelector('.node[data-id="EmrPat_Allergies"]'); if (n) n.dispatchEvent(new MouseEvent('click',{bubbles:true})); })()""")
    pg.wait_for_timeout(300)
    out.append(("qref count", pg.locator(".qref").count()))

    # reset view button works
    pg.evaluate("document.getElementById('btnClear').click()")
    pg.wait_for_timeout(300)
    out.append(("reset mode label", pg.locator(".viewlabel").count()))

    for o in out: print(o)
    for e in errs[:15]: print("ERR:", e)
    b.close()