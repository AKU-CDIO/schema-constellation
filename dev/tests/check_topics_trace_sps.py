from playwright.sync_api import sync_playwright

BASE = "http://127.0.0.1:8123"

with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page()
    errs = []
    pg.on("console", lambda m: errs.append(m.text) if m.type == "error" else None)

    # --- sps.html search + deep link + trace ---
    pg.goto(BASE + "/sps.html", wait_until="networkidle")
    pg.wait_for_selector("#spList .sp-card")
    n_cards = pg.eval_on_selector_all("#spList .sp-card", "els => els.length")
    n_blocks = pg.eval_on_selector_all("#spList .topic-block", "els => els.length")
    pg.fill("#spSearch", "Diagnoses")
    pg.wait_for_timeout(300)
    vis_cards = pg.eval_on_selector_all("#spList .sp-card", "els => els.filter(e => e.offsetParent !== null).length")
    vis_blocks = pg.eval_on_selector_all("#spList .topic-block", "els => els.filter(e => e.offsetParent !== null).length")
    count = pg.inner_text("#spSearchCount")
    pg.fill("#spSearch", "")

    # deep link sp-diagnosis
    pg.evaluate("location.hash = 'sp-diagnosis'")
    pg.wait_for_timeout(500)
    hl = pg.eval_on_selector_all(".topic-block.flash", "els => els.length")
    first_open = pg.eval_on_selector_all(".topic-block details.sql-card[open]", "els => els.length")

    # trace in sps? sps does not have trace; skip. Test copy button still works via first copy-btn
    copy_ok = pg.eval_on_selector_all("#spList .sql-card .copy-btn", "els => els.length")

    # --- topics.html search + trace + deep link ---
    pg.goto(BASE + "/topics.html", wait_until="networkidle")
    pg.wait_for_selector("#topics .topic-block")
    t_cards = pg.eval_on_selector_all("#topics .sp-card", "els => els.length")
    t_blocks = pg.eval_on_selector_all("#topics .topic-block", "els => els.length")
    pg.fill("#tpSearch", "AdmVitalSigns")
    pg.wait_for_timeout(300)
    tvis_cards = pg.eval_on_selector_all("#topics .sp-card", "els => els.filter(e => e.offsetParent !== null).length")
    tvis_blocks = pg.eval_on_selector_all("#topics .topic-block", "els => els.filter(e => e.offsetParent !== null).length")
    pg.fill("#tpSearch", "")

    # trace one patient
    first = pg.query_selector("#topics .topic-block")
    details_els = first.query_selector_all("details.sql-card")
    details_els[1].query_selector("summary").click()  # open trace details
    pg.wait_for_timeout(200)
    first.query_selector(".trace-btn").click()  # empty -> focus, no output
    pg.wait_for_timeout(200)
    first.query_selector(".trace-pid").fill("123456789")
    first.query_selector(".trace-btn").click()
    pg.wait_for_timeout(300)
    trace_sql = first.eval_on_selector(".trace-code", "e => e.textContent")
    has_out = "OutRows" in trace_sql
    has_join = "JoinRows" in trace_sql
    has_expect = "EXPECT" in trace_sql
    has_undef = "undefined" in trace_sql
    trace_copy = first.eval_on_selector(".trace-copy", "e => e.getAttribute('data-sql')")
    tc_has = "TRACE ONE PATIENT" in trace_copy

    # deep link topics#encounter
    pg.evaluate("location.hash = 'encounter'")
    pg.wait_for_timeout(500)
    t_hl = pg.eval_on_selector_all("#topics .topic-block.flash", "els => els.length")
    t_first_open = pg.eval_on_selector_all("#topics .topic-block details.sql-card[open]", "els => els.length")

    b.close()

    print(f"sps cards={n_cards} blocks={n_blocks} searchVis={vis_cards}/{n_cards} visBlocks={vis_blocks}/{n_blocks} count='{count}'")
    print(f"sps deep-link flash={hl} openDetails={first_open} copyBtns={copy_ok}")
    print(f"topics cards={t_cards} blocks={t_blocks} searchVis={tvis_cards}/{t_cards} visBlocks={tvis_blocks}/{t_blocks}")
    print(f"topics trace: OutRows={has_out} JoinRows={has_join} EXPECT={has_expect} undefined={has_undef} copyHasTrace={tc_has}")
    print(f"topics deep-link flash={t_hl} openDetails={t_first_open}")
    print("CONSOLE ERRORS:", errs if errs else "none")
