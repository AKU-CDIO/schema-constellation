# -*- coding: utf-8 -*-
import json, sys
from playwright.sync_api import sync_playwright

VIEWS = [
    ("overview", "http://127.0.0.1:8123/explorer.html"),
    ("topic-diagnosis", "http://127.0.0.1:8123/explorer.html#topic=diagnosis"),
    ("table", "http://127.0.0.1:8123/explorer.html#tbl=AbsAcct_Diagnoses"),
    ("question", "http://127.0.0.1:8123/explorer.html#q=diabetes_dx"),
]

JS = """(() => {
  const svg = document.getElementById('svg');
  const vw = svg.clientWidth, vh = svg.clientHeight;
  const g = document.querySelector('#svg > g');
  const tr = g.getAttribute('transform');
  const m = tr.match(/translate\\(([^)]+)\\) scale\\(([^)]+)\\)/);
  const tx = parseFloat(m[1].split(' ')[0]), ty = parseFloat(m[1].split(' ')[1]), k = parseFloat(m[2]);
  const nodes = [...document.querySelectorAll('.node')];
  let minX=1e9,minY=1e9,maxX=-1e9,maxY=-1e9;
  let minFont=1e9, maxFont=-1e9, badFont=[];
  const boxes = [];
  nodes.forEach(n => {
    const id = n.getAttribute('data-id');
    const card = n.querySelector('.card');
    const t = n.getAttribute('transform');
    const mm = t.match(/translate\\((-?[\\d.]+) (-?[\\d.]+)\\)/);
    const ox = parseFloat(mm[1]), oy = parseFloat(mm[2]);
    const cw = parseFloat(card.getAttribute('width')), ch = parseFloat(card.getAttribute('height'));
    const sx = ox*k+tx, sy = oy*k+ty;
    boxes.push({ id, x:sx, y:sy, w:cw*k, h:ch*k });
    minX=Math.min(minX,sx); minY=Math.min(minY,sy);
    maxX=Math.max(maxX,sx+cw*k); maxY=Math.max(maxY,sy+ch*k);
    const nm = n.querySelector('.nm');
    const fs = parseFloat(getComputedStyle(nm).fontSize);
    if (fs < minFont) minFont = fs;
    if (fs > maxFont) maxFont = fs;
    if (fs < 7) badFont.push({ id, fs });
  });
  const overlaps = [];
  for (let i=0;i<boxes.length;i++){
    for (let j=i+1;j<boxes.length;j++){
      const a=boxes[i], b=boxes[j];
      const ox = Math.min(a.x+a.w,b.x+b.w)-Math.max(a.x,b.x);
      const oy = Math.min(a.y+a.h,b.y+b.h)-Math.max(a.y,b.y);
      if (ox>0 && oy>0) overlaps.push({ a:a.id, b:b.id, area:ox*oy });
    }
  }
  overlaps.sort((x,y)=>y.area-x.area);
  const nodeCount = nodes.length;
  return { vw, vh, tx, ty, k, nodeCount, bbox:[minX,minY,maxX,maxY],
    minFont, maxFont, badFont, overlapPairs:overlaps.length,
    topOverlaps:overlaps.slice(0,8),
    nodesAtViewport: boxes.filter(b=>b.x< -50 || b.x+b.w> vw+50 || b.y<-50 || b.y+b.h>vh+50).length };
})()"""

with sync_playwright() as p:
    b = p.chromium.launch()
    for name, url in VIEWS:
        pg = b.new_page(viewport={"width": 1680, "height": 940})
        pg.goto(url)
        pg.wait_for_timeout(1800)
        info = pg.evaluate(JS)
        print("=" * 60)
        print(name)
        print(json.dumps(info, indent=1))
        pg.close()
    b.close()
