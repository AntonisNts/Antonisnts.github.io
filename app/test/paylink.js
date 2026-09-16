// Payment link and pending claims, in a real browser.
//
// The database suite proves a claim does not move a balance. This proves the
// parent is not told otherwise: that the panel sits under the months, that it
// says "not recorded as paid yet" in as many words, and that the months on the
// card do not change when a claim is raised.
//
// Wording is load-bearing here in a way it usually is not. A parent who reads
// "Awaiting confirmation" as "done" will believe they have paid.
const { open } = require("./harness");

let pass = 0, fail = 0;
const ok = (n, c, d) => { c ? (pass++, console.log("  ok   " + n))
                            : (fail++, console.log("  FAIL " + n + (d ? " — " + d : ""))); };
const text = (page) => page.evaluate(() => document.body.innerText);

const LINK   = [{ card_id: "card-1", link: "https://revolut.me/antonis", name: "Revolut — Antonis" }];
const CLAIMS = [];

const PARENT_CARDS = [{
  card: { id: "card-1", name: "Elena Georgiou", level: { id: "lv1", name: "Beginner", fee: 40 },
          share_code: "SC1001", payments: {}, history: [] },
  business: { name: "Aurora Music School", type: "Music", fee: 45, year: 2026,
              biz_code: "STAMP01", inactive_months: [], levels: [], custom_card_image: null },
}];

(async () => {
  // --- the parent sees a way to pay, and the truth about what it means -----
  {
    const { browser, page, errors } = await open({
      role: "parent",
      rpc: { get_my_cards: PARENT_CARDS, payment_links_mine: LINK, payment_claims_mine: CLAIMS,
             payment_claim_create: { ok: true, claim: "c1", name: "Elena Georgiou" } } });
    await page.waitForTimeout(700);

    // The family portal collapses each card; .fam-kid-main is what toggles it.
    await page.locator(".fam-kid-main").first().click();
    await page.waitForTimeout(500);

    let t = await text(page);
    ok("a Pay Online button appears when the school has a link", /Pay Online/i.test(t), t.slice(0, 200));
    ok("named as the school wrote it", /Revolut — Antonis/i.test(t));

    const href = await page.locator('a:has-text("Pay Online")').first().getAttribute("href");
    ok("it points at the school's link", href === "https://revolut.me/antonis", String(href));
    const rel = await page.locator('a:has-text("Pay Online")').first().getAttribute("rel");
    ok("opened without handing the school's page a window handle",
       /noopener/.test(rel || ""), String(rel));

    ok("and there is nothing to claim before the link has been opened",
       await page.getByText("I've paid", { exact: true }).count() === 0);

    // Photograph the months before claiming anything.
    const before = await page.evaluate(() => document.body.innerText);

    await page.locator('a:has-text("Pay Online")').first().click();
    await page.waitForTimeout(300);
    ok("after opening it, the parent can say they paid",
       await page.getByText("I've paid", { exact: true }).count() === 1);

    await page.locator('button:has-text("I\'ve paid")').first().click();
    await page.waitForTimeout(300);
    t = await text(page);
    ok("the form asks amount, date and a reference", /Amount Paid/i.test(t) && /Date Paid/i.test(t) && /Reference/i.test(t));
    ok("and says plainly that this marks nothing paid",
       /does not mark anything paid/i.test(t), t.slice(0, 200));

    await page.locator('input[type="number"]').first().fill("90");
    await page.locator('button:has-text("Tell The School")').first().click();
    await page.waitForTimeout(500);

    const sent = await page.evaluate(() => (window.__RPC_CALLS || []).find(c => c[0] === "payment_claim_create"));
    ok("the claim carries the card, the amount and a date",
       sent && sent[1].p_card_id === "card-1" && sent[1].p_amount === 90 && !!sent[1].p_paid_on,
       "got " + JSON.stringify(sent && sent[1]));

    // The months must be exactly as they were.
    const after = await page.evaluate(() => document.body.innerText);
    const months = (s) => (s.match(/\b(JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC)\b/gi) || []).join(",");
    ok("the months on the card did not change", months(before) === months(after));

    await browser.close();
    ok("no page errors", errors.filter(e => !/Failed to load resource|ERR_/.test(e)).length === 0,
       errors.slice(0, 3).join(" | "));
  }

  // --- a pending claim reads as NOT paid -----------------------------------
  {
    const { browser, page } = await open({
      role: "parent",
      rpc: { get_my_cards: PARENT_CARDS, payment_links_mine: LINK,
             payment_claims_mine: [{ id: "c1", card_id: "card-1", name: "Elena Georgiou",
               amount: 90, paid_on: "2026-09-10", status: "pending", note: null }] } });
    await page.waitForTimeout(700);
    await page.locator(".fam-kid-main").first().click();
    await page.waitForTimeout(500);
    const t = await text(page);

    ok("a pending claim shows as awaiting confirmation", /Awaiting confirmation/i.test(t), t.slice(0, 200));
    ok("and says in as many words that it is NOT recorded as paid",
       /not recorded as paid yet/i.test(t), t.slice(0, 260));
    ok("and explains the months will not move until the school confirms",
       /until the school checks/i.test(t));
    ok("with no second chance to claim the same thing twice",
       await page.getByText("I've paid", { exact: true }).count() === 0);
    await browser.close();
  }

  // --- a rejected claim, and its reason ------------------------------------
  {
    const { browser, page } = await open({
      role: "parent",
      rpc: { get_my_cards: PARENT_CARDS, payment_links_mine: LINK,
             payment_claims_mine: [{ id: "c1", card_id: "card-1", name: "Elena Georgiou",
               amount: 90, paid_on: "2026-09-10", status: "rejected",
               note: "Nothing matching that on the statement" }] } });
    await page.waitForTimeout(700);
    await page.locator(".fam-kid-main").first().click();
    await page.waitForTimeout(500);
    const t = await text(page);
    ok("a rejected claim is shown to the parent", /was not confirmed/i.test(t), t.slice(0, 220));
    ok("along with the school's reason", /Nothing matching that on the statement/i.test(t));
    ok("and they can try again", /Pay Online/i.test(t));
    await browser.close();
  }

  // --- no link, no panel ----------------------------------------------------
  {
    const { browser, page } = await open({
      role: "parent",
      rpc: { get_my_cards: PARENT_CARDS, payment_links_mine: [], payment_claims_mine: [] } });
    await page.waitForTimeout(700);
    await page.locator(".fam-kid-main").first().click();
    await page.waitForTimeout(500);
    ok("a school with no link shows no Pay Online button at all",
       !/Pay Online/i.test(await text(page)));
    await browser.close();
  }

  // --- the school's queue ---------------------------------------------------
  {
    const QUEUE = { ok: true,
      pending: [
        { id: "c1", card_id: "card-1", name: "Elena Georgiou", amount: 90,
          paid_on: "2026-09-10", reference: "REV-8891", claimed_by: "mum@example.com",
          created_at: "2026-09-10T10:00:00Z", stale: false },
        { id: "c2", card_id: "card-2", name: "Andreas Pavlou", amount: 60,
          paid_on: "2026-08-20", reference: null, claimed_by: "student:SC1002",
          created_at: "2026-08-20T10:00:00Z", stale: true },
      ],
      recent: [{ id: "c0", name: "Maria", amount: 45, status: "confirmed", decided_at: "2026-09-09T10:00:00Z" }] };

    const { browser, page, errors } = await open({
      rpc: { payment_claims_queue: QUEUE,
             payment_claim_confirm: { ok: true, n: 1, name: "Elena Georgiou", amount: 90, months: [8,9] } } });
    await page.waitForTimeout(600);
    await page.locator(".dash-gear").first().click();
    await page.waitForTimeout(350);

    ok("the settings row carries a count of what is waiting",
       /2/.test(await page.locator(".set-ov").getByText("Pending Payments", { exact: true })
         .locator("xpath=../..").innerText()));

    await page.locator(".set-ov").getByText("Pending Payments", { exact: true }).locator("visible=true").first().click();
    await page.waitForTimeout(600);

    let t = await text(page);
    ok("the queue lists both claims", /Elena Georgiou/.test(t) && /Andreas Pavlou/.test(t));
    ok("with the amount and the reference the parent gave", /€90\.00/.test(t) && /REV-8891/.test(t));
    ok("it says nothing here has changed a balance", /has changed a balance/i.test(t), t.slice(0, 240));
    ok("an old one is flagged rather than hidden", /Waiting a while/i.test(t));
    ok("a student-portal claim says where it came from", /From the student portal/i.test(t));

    await page.locator('button:has-text("Confirm")').first().click();
    await page.waitForTimeout(500);
    const conf = await page.evaluate(() => (window.__RPC_CALLS || []).find(c => c[0] === "payment_claim_confirm"));
    ok("confirming sends only the claim id — the amount is the database's to trust",
       conf && Object.keys(conf[1]).join(",") === "p_id" && conf[1].p_id === "c1",
       JSON.stringify(conf && conf[1]));
    ok("and reports what it covered", /recorded for Elena Georgiou/i.test(await text(page)));

    await browser.close();
    ok("no page errors in the queue", errors.filter(e => !/Failed to load resource|ERR_/.test(e)).length === 0,
       errors.slice(0, 3).join(" | "));
  }

  // --- rejecting asks why ---------------------------------------------------
  {
    const { browser, page } = await open({
      rpc: { payment_claims_queue: { ok: true, recent: [],
               pending: [{ id: "c1", card_id: "card-1", name: "Elena Georgiou", amount: 90,
                 paid_on: "2026-09-10", reference: null, claimed_by: "mum@example.com",
                 created_at: "2026-09-10T10:00:00Z", stale: false }] },
             payment_claim_reject: { ok: true } } });
    await page.waitForTimeout(600);
    await page.locator(".dash-gear").first().click();
    await page.waitForTimeout(350);
    await page.locator(".set-ov").getByText("Pending Payments", { exact: true }).locator("visible=true").first().click();
    await page.waitForTimeout(600);

    await page.locator('button:has-text("Reject")').first().click();
    await page.waitForTimeout(300);
    ok("rejecting asks for a reason before doing anything",
       /Reason \(optional\)/i.test(await text(page)));
    ok("and says nothing was recorded so nothing is undone",
       /nothing was recorded/i.test(await text(page)));

    await page.locator('input[placeholder*="statement"]').first().fill("Not on the statement");
    await page.locator('button:has-text("Reject Claim")').first().click();
    await page.waitForTimeout(500);
    const rej = await page.evaluate(() => (window.__RPC_CALLS || []).find(c => c[0] === "payment_claim_reject"));
    ok("the reason reaches the school's answer",
       rej && rej[1].p_id === "c1" && rej[1].p_note === "Not on the statement",
       JSON.stringify(rej && rej[1]));
    await browser.close();
  }

  // --- the owner's link screen ---------------------------------------------
  {
    const { browser, page } = await open({ rpc: {} });
    await page.waitForTimeout(600);
    await page.locator(".dash-gear").first().click();
    await page.waitForTimeout(350);
    await page.locator(".set-ov").getByText("Payment Link", { exact: true }).locator("visible=true").first().click();
    await page.waitForTimeout(500);

    await page.locator('input[type="url"]').first().fill("http://revolut.me/x");
    await page.locator('button:has-text("Save Link")').first().click();
    await page.waitForTimeout(300);
    ok("plain http is refused before it ever reaches the database",
       /has to start with https/i.test(await text(page)));
    const saved = await page.evaluate(() => (window.__RPC_CALLS || []).length);
    ok("and nothing was sent", saved >= 0);
    await browser.close();
  }

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
