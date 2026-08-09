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
    pg.wait_for_timeout(1600)
    print("overview edges by class:", pg.evaluate("(() => { const e = {}; document.querySelectorAll('.edge').forEach(x => { const k = [...x.classList].find(c => c === 'kp' || c === 'kv' || c === 'ko'); e[k] = (e[k]||0)+1; }); return JSON.stringify(e); })()"))
    print("edge stroke sample:", pg.evaluate("(() => { const x = document.querySelector('.edge.kp, .edge.kv, .edge.ko'); return x ? getComputedStyle(x).stroke : null })()"))
    print("legend has key chips:", pg.evaluate("Array.from(document.querySelectorAll('.legend .z')).map(z => z.textContent).filter(t => t.includes('key'))"))
    print("visit filter present:", pg.evaluate("!!document.getElementById('visitOnly')"), "| count:", pg.evaluate("document.getElementById('vfCount').textContent"))
    pg.evaluate("document.getElementById('visitOnly').click()")
    pg.wait_for_timeout(400)
    print("after filter nodes:", pg.evaluate("document.querySelectorAll('.node').length"))
    pg.evaluate("document.getElementById('visitOnly').click()")
    pg.wait_for_timeout(400)
    print("after unfilter nodes:", pg.evaluate("document.querySelectorAll('.node').length"))
    pg.goto("http://127.0.0.1:8123/explorer.html#topic=diagnosis")
    pg.wait_for_timeout(1400)
    print("topic label colors:", pg.evaluate("(() => { const s = new Set(); document.querySelectorAll('.edgelabel').forEach(x => s.add(getComputedStyle(x).fill)); return [...s]; })()"))
    print("console errors:", errs if errs else "none")
    pg.close()
    b.close()
