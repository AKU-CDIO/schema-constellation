# -*- coding: utf-8 -*-
from playwright.sync_api import sync_playwright
errs = []
with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1680, "height": 940})
    pg.on("console", lambda m: errs.append(m.text) if m.type == "error" else None)
    pg.on("pageerror", lambda e: errs.append(str(e)))
    # 1. fresh load with a topic route
    pg.goto("http://127.0.0.1:8123/explorer.html#topic=diagnosis")
    pg.wait_for_timeout(1500)
    print("1 mode:", pg.evaluate("state.mode"), "| hash:", pg.evaluate("location.hash"))
    print("1 detail hidden:", pg.evaluate("document.querySelector('#detail').classList.contains('hidden')"))
    # 2. click a node -> detail opens, hash becomes #tbl
    pg.evaluate("document.querySelector('#svg g.node[data-id=\\'AbsAcct_Diagnoses\\']').dispatchEvent(new MouseEvent('click',{bubbles:true}))")
    pg.wait_for_timeout(400)
    print("2 mode:", pg.evaluate("state.mode"), "| hash:", pg.evaluate("location.hash"))
    print("2 detail hidden:", pg.evaluate("document.querySelector('#detail').classList.contains('hidden')"))
    print("2 detail name:", pg.evaluate("document.querySelector('#detail h2')?.textContent"))
    # 3. browser Back -> detail should close, topic view returns
    pg.go_back()
    pg.wait_for_timeout(500)
    print("3 hash:", pg.evaluate("location.hash"))
    print("3 mode:", pg.evaluate("state.mode"))
    print("3 detail hidden:", pg.evaluate("document.querySelector('#detail').classList.contains('hidden')"))
    # 4. click node again, then Back twice (to empty hash -> overview)
    pg.evaluate("document.querySelector('#svg g.node[data-id=\\'AbsAcct_Diagnoses\\']').dispatchEvent(new MouseEvent('click',{bubbles:true}))")
    pg.wait_for_timeout(300)
    print("4 hash:", pg.evaluate("location.hash"))
    pg.go_back(); pg.wait_for_timeout(400)
    print("5 back hash:", pg.evaluate("location.hash"), "| detail hidden:", pg.evaluate("document.querySelector('#detail').classList.contains('hidden')"))
    print("console errors:", errs if errs else "none")
    pg.close()
    b.close()
