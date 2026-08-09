# -*- coding: utf-8 -*-
import json
from playwright.sync_api import sync_playwright

BASE = "http://127.0.0.1:8123/explorer.html"

def run(b, pg, label, checks):
    errors = []
    pg.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
    pg.on("pageerror", lambda e: errors.append(str(e)))
    for name, fn in checks:
        try:
            fn(pg)
            print("  PASS:", name)
        except AssertionError as e:
            print("  FAIL:", name, "->", e)
        except Exception as e:
            print("  ERROR:", name, "->", type(e).__name__, str(e))
    if errors:
        print("  CONSOLE ERRORS:", errors[:5])
    else:
        print("  CONSOLE ERRORS: none")

with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1680, "height": 940})
    pg.goto(BASE)
    pg.wait_for_timeout(1800)
    print("== overview ==")
    run(b, pg, "overview", [
        ("184 nodes", lambda g: g.evaluate("document.querySelectorAll('.node').length") == 184),
        ("11 category groups", lambda g: g.evaluate("document.querySelectorAll('#doctopics .catalog-group').length") == 11),
        ("doc topics count", lambda g: g.evaluate("document.querySelectorAll('#doctopics .dtopic').length")),
        ("groups collapsed by default", lambda g: g.evaluate("document.querySelectorAll('#doctopics .catalog-group.open').length") == 0),
        ("overlap pairs <= 6", lambda g: g.evaluate("""(() => {
          const ns=[...document.querySelectorAll('.node')];
          const boxes=ns.map(n=>{
            const c=n.querySelector('.card'); const t=n.getAttribute('transform');
            const m=t.match(/translate\\((-?[\\d.]+) (-?[\\d.]+)\\)/);
            const ox=parseFloat(m[1]),oy=parseFloat(m[2]);
            const k=parseFloat(document.querySelector('#svg > g').getAttribute('transform').match(/scale\\(([^)]+)\\)/)[1]);
            return {x:ox*k,y:oy*k,w:parseFloat(c.getAttribute('width'))*k,h:parseFloat(c.getAttribute('height'))*k};
          }); let o=0;
          for(let i=0;i<boxes.length;i++)for(let j=i+1;j<boxes.length;j++){
            const a=boxes[i],b=boxes[j];
            const ox=Math.min(a.x+a.w,b.x+b.w)-Math.max(a.x,b.x);
            const oy=Math.min(a.y+a.h,b.y+b.h)-Math.max(a.y,b.y);
            if(ox>0&&oy>0)o++;
          } return o;
        })()""") <= 6),
        ("font screen >= 8px", lambda g: g.evaluate("""(() => {
          const k=parseFloat(document.querySelector('#svg > g').getAttribute('transform').match(/scale\\(([^)]+)\\)/)[1]);
          const nm=document.querySelector('.node .nm');
          return parseFloat(getComputedStyle(nm).fontSize)*k >= 8;
        })()""")),
    ])

    print("== doc topic panel ==")
    pg.evaluate("""(() => {
      [...document.querySelectorAll('#doctopics .catalog-group')].find(g=>g.textContent.includes('Diagnoses & Problem List')).querySelector('.cg-head').click();
      const rows=[...document.querySelectorAll('#doctopics .dtopic')];
      rows.find(r=>r.textContent.includes('Diagnosis')).click();
    })()""")
    pg.wait_for_timeout(300)
    run(b, pg, "panel", [
        ("panel open", lambda g: g.evaluate("!document.getElementById('detail').classList.contains('hidden')")),
        ("AVAILABLE chip", lambda g: g.evaluate("document.querySelector('#detail .chip').textContent") == "AVAILABLE"),
        ("at tables listed", lambda g: g.evaluate("document.querySelectorAll('#detail .cg-tbl').length") >= 3),
        ("show in graph btn", lambda g: g.evaluate("!!document.getElementById('docGraphBtn')")),
        ("validation query", lambda g: g.evaluate("document.querySelector('#detail .sqlbox pre').textContent.includes('AbsAcct_Diagnoses')")),
    ])

    print("== doc in graph ==")
    pg.click("#docGraphBtn")
    pg.wait_for_timeout(400)
    run(b, pg, "graph", [
        ("mode doc", lambda g: g.evaluate("state.mode") == "doc"),
        ("nodes > 0", lambda g: g.evaluate("document.querySelectorAll('.node').length") > 0),
    ])

    print("== deep link #topic=doc: ==")
    pg2 = b.new_page(viewport={"width": 1680, "height": 940})
    pg2.goto(BASE + "#topic=doc:Lab%20Results")
    pg2.wait_for_timeout(1500)
    run(b, pg2, "link", [
        ("panel shows Lab Results", lambda g: g.evaluate("document.getElementById('detail').textContent.includes('Lab Results')")),
        ("has LabRes_Main row", lambda g: g.evaluate("document.getElementById('detail').textContent.includes('LabRes_Main')")),
    ])
    pg2.close()

    b.close()
