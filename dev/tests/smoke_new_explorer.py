# -*- coding: utf-8 -*-
import sys, json
from playwright.sync_api import sync_playwright

URL = "http://127.0.0.1:8123/explorer.html"
errors = []
with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1680, "height": 940})
    pg.on("console", lambda m: errors.append(("console", m.type, m.text)))
    pg.on("pageerror", lambda e: errors.append(("pageerror", "error", str(e))))
    pg.goto(URL)
    pg.wait_for_timeout(2500)
    print("nodes:", pg.locator(".node").count())
    print("edges:", pg.locator(".edge").count())
    print("topics:", pg.locator(".topic").count())
    print("legend z rows:", pg.locator("#legend .z").count())
    print("brand h1:", pg.locator(".brand h1").inner_text())
    print("legend has Reset View:", pg.locator("#btnClear").count())
    print("birdseye button present:", pg.locator("#btnOverview").count())
    # hover a node -> tooltip shows icon + name
    pg.locator(".node").first.hover()
    pg.wait_for_timeout(300)
    tip_vis = pg.evaluate("document.querySelector('#tip').style.display")
    tt = pg.evaluate("(document.querySelector('#tip .tt')||{}).innerText || ''")
    ticon = pg.evaluate("!!document.querySelector('#tip .ticon svg')")
    print("tip visible:", tip_vis, "| tt:", tt, "| icon:", ticon)
    # click node -> detail panel
    pg.locator(".node").first.click()
    pg.wait_for_timeout(300)
    detail_vis = pg.evaluate("!document.getElementById('detail').classList.contains('hidden')")
    keychips = pg.locator(".keychip").count()
    rels = pg.locator(".rels .rel").count()
    sqlpre = pg.evaluate("(document.querySelector('.sqlbox pre')||{}).innerText || ''")
    print("detail open:", detail_vis, "| keychips:", keychips, "| rel rows:", rels)
    print("sql snippet len:", len(sqlpre))
    # check svg transform is applied (fit)
    tr = pg.evaluate("document.querySelector('#svg > g').getAttribute('transform')")
    print("view transform:", tr)
    for t in errors[:20]:
        print("ERR:", t)
    b.close()
