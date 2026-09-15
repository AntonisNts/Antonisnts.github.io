// The stamp trigger, driven with real multi-touch events.
//
// What matters here is the browser half: that the flag really gates it, that a
// press staggered across several touchstart events is still collected whole,
// that the points sent up are normalised so contact order cannot matter, and
// that a non-match does nothing visible. The matching itself is the database's
// job and is covered in supabase/test/test-stamp-geometry.sql.
const { open } = require("./harness");

let pass = 0, fail = 0;
const ok = (n, c, d) => { c ? (pass++, console.log("  ok   " + n))
                            : (fail++, console.log("  FAIL " + n + (d ? " — " + d : ""))); };

const SESSION = {
  ok: true, confirmation: "c0000000-0000-0000-0000-000000000009",
  expires_at: new Date(Date.now() + 60000).toISOString(),
  trigger: "stamp", require_pin: false, business_name: "Aurora Music School",
  type: "Music", accent: "violet", icon: null, year: 2026,
  students: [{ card_id: "card-1", name: "Elena Georgiou", amount: 45, month: "March" }],
};

// A five-pad stamp, pressed at an arbitrary spot on the screen.
const PADS = [[120, 300], [180, 300], [120, 360], [180, 360], [140, 335]];

// Deliver a press the way a screen actually does: contacts arriving over a few
// events, not one tidy five-touch event.
async function press(page, pts, stagger) {
  await page.evaluate(([pts, stagger]) => {
    const mk = (list) => {
      const touches = list.map((p, i) => new Touch({
        identifier: i, target: document.body, clientX: p[0], clientY: p[1] }));
      return new TouchEvent("touchstart", { touches, targetTouches: touches,
        changedTouches: touches, bubbles: true, cancelable: true });
    };
    if (stagger) {
      // One contact, then three, then all five — the realistic case.
      document.body.dispatchEvent(mk(pts.slice(0, 1)));
      setTimeout(() => document.body.dispatchEvent(mk(pts.slice(0, 3))), 10);
      setTimeout(() => document.body.dispatchEvent(mk(pts)), 25);
    } else {
      document.body.dispatchEvent(mk(pts));
    }
  }, [pts, stagger]);
  await page.waitForTimeout(500);
}

const calls = (page) => page.evaluate(() => (window.__RPC_CALLS || [])
  .filter(c => c[0] === "stamp_begin_geometry").map(c => c[1]));
const text = (page) => page.evaluate(() => document.body.innerText);

(async () => {
  // --- off by default ------------------------------------------------------
  {
    const { browser, page } = await open({ role: "parent", rpc: { get_my_cards: [], stamp_begin_geometry: SESSION } });
    await page.waitForTimeout(500);
    await press(page, PADS, false);
    ok("with the flag unset, a press is not even sent", (await calls(page)).length === 0);
    const on = await page.evaluate(() => { try { return localStorage.getItem("ps_stamp_trigger"); } catch (e) { return "throw"; } });
    ok("and nothing was switched on behind the scenes", on === null, JSON.stringify(on));
    await browser.close();
  }

  // --- switched on ---------------------------------------------------------
  {
    const { browser, page, errors } = await open({
      query: "?stamptrigger=1", role: "parent",
      rpc: { get_my_cards: [], stamp_begin_geometry: SESSION,
             stamp_confirm: { ok: true, n: 1, name: "Elena Georgiou", amount: 45, months: [2], trigger: "stamp" } },
    });
    await page.waitForTimeout(500);

    await press(page, [[100, 100], [140, 100], [100, 140]], false);
    ok("three contacts are below the floor and are not sent", (await calls(page)).length === 0);

    await press(page, PADS, true);
    const c = await calls(page);
    ok("a press staggered over several events is still collected whole",
       c.length === 1 && c[0].p_points.length === 5,
       JSON.stringify(c[0] && c[0].p_points));

    const pts = c[0].p_points;
    ok("the points are sent relative to the leftmost, not as screen coordinates",
       pts[0][0] === 0 && pts[0][1] === 0 && pts.every(p => p[0] >= 0),
       JSON.stringify(pts));
    ok("and they describe the stamp's actual shape",
       JSON.stringify(pts) === JSON.stringify([[0,0],[0,60],[20,35],[60,0],[60,60]]),
       JSON.stringify(pts));

    ok("a match opens the confirmation", /Aurora Music School/i.test(await text(page)));
    ok("prefilled from the session, like every other trigger",
       (await page.locator('input[type="number"]').inputValue()) === "45");

    await page.getByText("Confirm Payment").first().click();
    await page.waitForTimeout(400);
    ok("and it goes through the same confirm call", /Payment recorded/i.test(await text(page)));
    const conf = await page.evaluate(() => (window.__RPC_CALLS || []).find(c => c[0] === "stamp_confirm"));
    ok("carrying the session the trigger opened, nothing invented locally",
       conf && conf[1].p_confirmation === SESSION.confirmation);

    await browser.close();
    ok("no page errors", errors.filter(e => !/Failed to load resource|ERR_/.test(e)).length === 0,
       errors.slice(0, 3).join(" | "));
  }

  // --- contact order ------------------------------------------------------
  {
    const { browser, page } = await open({
      query: "?stamptrigger=1", role: "parent",
      rpc: { get_my_cards: [], stamp_begin_geometry: { error: "no_match" } } });
    await page.waitForTimeout(500);
    await press(page, PADS.slice().reverse(), false);
    const a = (await calls(page))[0].p_points;
    await press(page, [PADS[2], PADS[4], PADS[0], PADS[3], PADS[1]], false);
    await page.waitForTimeout(2700);                    // clear the cooldown
    const all = await calls(page);
    ok("the same stamp pressed in any order sends identical points",
       JSON.stringify(a) === JSON.stringify(all[all.length - 1].p_points),
       JSON.stringify(a) + " vs " + JSON.stringify(all[all.length - 1].p_points));
    await browser.close();
  }

  // --- a non-match must be invisible --------------------------------------
  {
    const { browser, page } = await open({
      query: "?stamptrigger=1", role: "parent",
      rpc: { get_my_cards: [], stamp_begin_geometry: { error: "no_match" } } });
    await page.waitForTimeout(500);
    const before = await text(page);
    await press(page, [[10, 10], [200, 40], [30, 300], [260, 320]], false);
    ok("four fingers that match nothing were still offered to the database",
       (await calls(page)).length === 1);
    ok("and the screen does not change or say anything", (await text(page)) === before);
    await browser.close();
  }

  // --- not on the school's own dashboard ----------------------------------
  {
    const { browser, page } = await open({ query: "?stamptrigger=1", rpc: { stamp_begin_geometry: SESSION } });
    await page.waitForTimeout(600);
    await press(page, PADS, false);
    ok("a press on the school's own dashboard is ignored", (await calls(page)).length === 0);
    await browser.close();
  }

  // --- the flag can be turned back off ------------------------------------
  {
    const { browser, page } = await open({ query: "?stamptrigger=1", role: "parent",
      rpc: { get_my_cards: [], stamp_begin_geometry: SESSION } });
    await page.waitForTimeout(400);
    await page.goto(page.url().split("?")[0] + "?stamptrigger=0", { waitUntil: "domcontentloaded" });
    await page.waitForTimeout(700);
    await press(page, PADS, false);
    ok("switching the flag off stops the listening again", (await calls(page)).length === 0);
    await browser.close();
  }

  // --- the calibration screen, owner side ---------------------------------
  {
    const { browser, page } = await open({ rpc: { stamp_geometry_get: { ok: true, calibrated: false } } });
    await page.waitForTimeout(500);
    await page.locator(".dash-gear").first().click();
    await page.waitForTimeout(350);
    ok("with the flag off, no calibration screen is offered at all",
       await page.locator(".set-ov").getByText("Stamp", { exact: true }).count() === 0);
    await browser.close();
  }
  {
    const { browser, page, errors } = await open({
      query: "?stamptrigger=1",
      rpc: { stamp_geometry_get: { ok: true, calibrated: false },
             stamp_geometry_set: { ok: true, point_count: 5 } } });
    await page.waitForTimeout(500);
    await page.locator(".dash-gear").first().click();
    await page.waitForTimeout(350);
    await page.locator(".set-ov").getByText("Stamp", { exact: true }).locator("visible=true").first().click();
    await page.waitForTimeout(600);

    let t = await text(page);
    ok("the calibration screen opens", /Press the stamp here/i.test(t), t.slice(0, 120));
    ok("and says plainly that nothing is saved yet", /Nothing saved yet/i.test(t));

    // Press the stamp on the target pad.
    await page.evaluate((pts) => {
      const el = document.querySelector('[style*="dashed"]');
      const touches = pts.map((p, i) => new Touch({ identifier: i, target: el, clientX: p[0], clientY: p[1] }));
      el.dispatchEvent(new TouchEvent("touchstart", { touches, targetTouches: touches,
        changedTouches: touches, bubbles: true, cancelable: true }));
    }, PADS);
    await page.waitForTimeout(500);

    t = await text(page);
    ok("the press is caught and counted back", /5 pads registered/i.test(t), t.slice(0, 160));
    ok("and drawn, so a bad press can be seen", await page.locator("svg circle").count() === 5);

    await page.getByText(/Save This Pattern/i).first().click();
    await page.waitForTimeout(400);
    const set = await page.evaluate(() => (window.__RPC_CALLS || []).find(c => c[0] === "stamp_geometry_set"));
    ok("saving sends the normalised pattern, not raw screen coordinates",
       set && JSON.stringify(set[1].p_points) === JSON.stringify([[0,0],[0,60],[20,35],[60,0],[60,60]]),
       JSON.stringify(set && set[1].p_points));
    ok("along with this device's pixel ratio, so a later mismatch is diagnosable",
       set && typeof set[1].p_ratio === "number");

    await browser.close();
    ok("no page errors on the calibration screen",
       errors.filter(e => !/Failed to load resource|ERR_/.test(e)).length === 0,
       errors.slice(0, 3).join(" | "));
  }
  {
    const { browser, page } = await open({
      query: "?stamptrigger=1",
      rpc: { stamp_geometry_get: { ok: true, calibrated: false } } });
    await page.waitForTimeout(500);
    await page.locator(".dash-gear").first().click();
    await page.waitForTimeout(350);
    await page.locator(".set-ov").getByText("Stamp", { exact: true }).locator("visible=true").first().click();
    await page.waitForTimeout(600);
    await page.evaluate(() => {
      const el = document.querySelector('[style*="dashed"]');
      const pts = [[10,10],[60,10],[10,60]];
      const touches = pts.map((p, i) => new Touch({ identifier: i, target: el, clientX: p[0], clientY: p[1] }));
      el.dispatchEvent(new TouchEvent("touchstart", { touches, targetTouches: touches,
        changedTouches: touches, bubbles: true, cancelable: true }));
    });
    await page.waitForTimeout(500);
    const t2 = await text(page);
    ok("a half-landed press says how many pads registered rather than saving it",
       /3 pads registered/i.test(t2) && /press the whole stamp down flat/i.test(t2), t2.slice(0, 200));
    ok("and offers no save button for it",
       await page.getByText(/Save This Pattern/i).count() === 0);
    await browser.close();
  }

  // --- the student portal, which has no login at all ----------------------
  {
    const CARD = { business: { biz_code: "STAMP01", name: "Aurora Music School", type: "Music",
                     fee: 45, year: 2026, inactive_months: [], levels: [], accent: "violet" },
                   card: { name: "Elena Georgiou", share_code: "SC1001", payments: {}, history: [] },
                   announcements: [] };
    const { browser, page, errors } = await open({
      query: "?stamptrigger=1", signedOut: true,
      rpc: { get_student_card: CARD,
             stamp_begin_geometry_student: Object.assign({}, SESSION, { trigger: "stamp" }),
             stamp_confirm_student: { ok: true, n: 1, name: "Elena Georgiou", amount: 45, months: [2], trigger: "stamp" } } });
    await page.waitForTimeout(500);

    // Land on the student portal the way a student does: "Quick View" on the
    // landing page, then the share code, then the PIN.
    await page.getByText("Quick View", { exact: true }).first().click();
    await page.waitForTimeout(500);
    await page.locator("input").first().fill("SC1001");
    await page.locator("button").filter({ hasText: /^(?!.*back).*$/i }).last().click();
    await page.waitForTimeout(500);
    await page.locator("input").first().fill("1001");
    await page.locator("button").filter({ hasText: /^(?!.*back).*$/i }).last().click();
    await page.waitForTimeout(800);
    ok("the student card opens", /Elena Georgiou/i.test(await text(page)), (await text(page)).slice(0, 120));

    await press(page, PADS, true);
    const c = await page.evaluate(() => (window.__RPC_CALLS || [])
      .filter(x => x[0] === "stamp_begin_geometry_student").map(x => x[1]));
    ok("a press on the student card is sent, with the code and PIN it was opened with",
       c.length === 1 && c[0].p_code === "SC1001" && c[0].p_pin === "1001",
       JSON.stringify(c[0]));
    ok("and the same normalised points as the family portal sends",
       c.length === 1 && JSON.stringify(c[0].p_points) === JSON.stringify([[0,0],[0,60],[20,35],[60,0],[60,60]]),
       JSON.stringify(c[0] && c[0].p_points));

    ok("the confirmation opens over the card", /Confirm Payment/i.test(await text(page)));
    await page.getByText("Confirm Payment").first().click();
    await page.waitForTimeout(500);
    ok("and records through the student-portal call, not the family one",
       await page.evaluate(() => !!(window.__RPC_CALLS || []).find(x => x[0] === "stamp_confirm_student")
                              && !(window.__RPC_CALLS || []).find(x => x[0] === "stamp_confirm")));
    ok("reporting success", /Payment recorded/i.test(await text(page)));

    await browser.close();
    ok("no page errors in the student portal",
       errors.filter(e => !/Failed to load resource|ERR_/.test(e)).length === 0,
       errors.slice(0, 3).join(" | "));
  }

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
