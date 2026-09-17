// The family portal, after it stopped being one long scroll.
//
// The portal used to concatenate: the amount due, the pay-online panel, the
// shop, then every child with their card and their school's notes unfolding
// underneath. Each feature added another band to the front page, and the shop
// was the one that broke it — two children at one school listed the same
// jumper twice, above the children themselves.
//
// It is now a list of names. Tapping one opens that child: their card, where
// to pay, their notes, their shop. The duplication cannot come back, because
// two children are never on screen together.
//
// What this pins:
//   - the front page is names and nothing else
//   - a child's page is about that child and no sibling
//   - the same item is listed once, not once per child
//   - the stamp still fires from a child's page, untouched
const { open } = require("./harness");

let pass = 0, fail = 0;
const ok = (n, c, d) => { c ? (pass++, console.log("  ok   " + n))
                            : (fail++, console.log("  FAIL " + n + (d ? " — " + d : ""))); };
const text = (page) => page.evaluate(() => document.body.innerText);

const card = (i, name, school, payments, group) => ({
  card: { id: "card-" + i, name, level: { id: "lv1", name: "Beginner", fee: 40 },
          share_code: "SC100" + i, payments: payments || {}, history: [],
          group_id: group || null },
  business: { name: school, type: "Music", fee: 45, year: 2026, biz_code: "ST000" + i,
              inactive_months: [], levels: [], custom_card_image: null },
});

const TWO = [
  card(1, "Afrodite Marina Savva", "Dance School", {}),
  card(2, "Anais Ion", "Dance School", { "2026-01": { paid: true, amount: 40 } }),
];

// The screenshot that started this: one item, two children, one school.
const SAME_ITEM = [
  { card_id: "card-1", student: "Afrodite Marina Savva", school: "Dance School",
    items: [{ id: "i1", name: "Stoli", description: null, price: 10, sizes: [],
              out_of_stock: false, image_url: null }] },
  { card_id: "card-2", student: "Anais Ion", school: "Dance School",
    items: [{ id: "i1", name: "Stoli", description: null, price: 10, sizes: [],
              out_of_stock: false, image_url: null }] },
];

const NOTE = [{ id: "a1", business_name: "Dance School", title: "Recital on the 14th",
                body: "Main hall, 18:00", created_at: "2026-09-10T09:00:00Z",
                target_kind: "all", card_id: null, group_id: null, is_pinned: false }];

const row = (page, n) => page.locator(".fam-kid-main").nth(n);
// A child's page is tabbed. Everything except the card is one tap in.
const tab = async (page, name) => {
  const t = page.locator('.tab:has-text("' + name + '")');
  if (await t.count() === 0) return false;
  await t.first().click();
  await page.waitForTimeout(400);
  return true;
};

(async () => {
  // === the front page is names ==============================================
  {
    const { browser, page, errors } = await open({
      role: "parent",
      rpc: { get_my_cards: TWO, shop_catalogue_mine: SAME_ITEM, shop_orders_mine: [],
             get_my_announcements: NOTE, get_my_ann_reads: [] } });
    await page.waitForTimeout(800);
    const t = await text(page);

    ok("both children are named", /Afrodite Marina Savva/.test(t) && /Anais Ion/.test(t));
    ok("with their school and what they owe", /Dance School/.test(t) && /€\d+/.test(t));

    // The three bands that made it noisy. None of them belong here now.
    ok("THE SHOP IS NOT ON THE FRONT PAGE", !/Stoli/.test(t), t.slice(0, 400));
    ok("nor is the body of a school note", !/Main hall/.test(t), t.slice(0, 400));
    ok("nor a pay-online panel", !/Pay Online/i.test(t) && !/never handles payments/i.test(t),
       t.slice(0, 400));

    ok("each name is a way in, and says so", await page.locator(".fam-chev").count() === 2);
    // The notes moved behind the row, so the row has to carry the fact that
    // there is something unread to go and read.
    ok("an unread note puts a dot on the child it concerns",
       await page.locator(".fam-unread").count() === 2);

    await browser.close();
    ok("no page errors on the front page",
       errors.filter(e => !/Failed to load resource|ERR_/.test(e)).length === 0,
       errors.slice(0, 3).join(" | "));
  }

  // === a child's page =======================================================
  {
    const { browser, page, errors } = await open({
      role: "parent",
      rpc: { get_my_cards: TWO, shop_catalogue_mine: SAME_ITEM, shop_orders_mine: [],
             get_my_announcements: NOTE, get_my_ann_reads: [],
             payment_links_mine: [{ card_id: "card-1", link: "https://revolut.me/x", name: "Revolut" }],
             payment_claims_mine: [] } });
    await page.waitForTimeout(800);
    await row(page, 0).click();
    await page.waitForTimeout(600);

    let t = await text(page);
    ok("the page is titled with the child", /Afrodite Marina Savva/.test(t));
    // The card is what a page opens on -- it is what the parent came for.
    ok("and opens on their card and months",
       /MONTHS/i.test(t) && /JAN/i.test(t), t.slice(0, 300));
    ok("and where to pay", /Pay Online/i.test(t) && /Revolut/.test(t));
    const labels = (await page.locator(".tab").allInnerTexts())
      .map(x => x.split("\n")[0].trim());
    ok("the rest is behind tabs rather than stacked under it",
       labels.join(",") === "Card,School,Shop", labels.join(","));
    // The notes and the shop are not on the card tab, which is the point.
    ok("the card tab is not also the notes and the shop",
       !/Recital on the 14th/.test(t) && !/Stoli/.test(t), t.slice(0, 400));

    ok("their school's notes are one tap in", await tab(page, "School"));
    t = await text(page);
    ok("and are here when you get there", /Recital on the 14th/.test(t));

    ok("their shop is one tap in", await tab(page, "Shop"));
    t = await text(page);
    ok("and is here when you get there", /Stoli/.test(t));

    // The whole point of the restructure.
    ok("NOTHING ABOUT THE SIBLING IS ON THIS PAGE", !/Anais/.test(t), t.slice(0, 500));
    // The bug in the screenshot: one item, listed once per child.
    ok("THE SAME ITEM IS LISTED ONCE, NOT TWICE",
       (t.match(/Stoli/g) || []).length === 1, "found " + (t.match(/Stoli/g) || []).length);
    // Inside a tab called Shop, a heading saying Shop is the same word twice,
    // and captioning each block with the name already at the top of the page
    // is the same mistake again. The page title itself SHOULD name the child.
    const shopBody = await page.evaluate(() => {
      const bar = document.querySelector(".tabbar");
      return bar && bar.nextElementSibling ? bar.nextElementSibling.innerText : "";
    });
    ok("the shop tab repeats neither its own name nor the child's",
       !/Afrodite/i.test(shopBody) && !/^\s*SHOP\b/i.test(shopBody),
       JSON.stringify(shopBody.slice(0, 160)));

    await tab(page, "Card");
    ok("unlinking is on the card tab, named, rather than on the list",
       /Unlink Afrodite Marina Savva/.test(await text(page)));

    // Back, and the other child.
    await page.locator(".tb-back").first().click();
    await page.waitForTimeout(500);
    let back = await text(page);
    ok("back returns to the list", /Anais Ion/.test(back) && !/Stoli/.test(back));

    await row(page, 1).click();
    await page.waitForTimeout(600);
    let t2 = await text(page);
    ok("the other name opens the other child", /Anais Ion/.test(t2) && !/Afrodite/.test(t2));
    ok("and no pay-online panel, because their school published no link for them",
       !/Revolut/.test(t2), t2.slice(0, 300));
    await tab(page, "Shop");
    t2 = await text(page);
    ok("who has their own copy of the same item", /Stoli/.test(t2));
    ok("and still nothing of their sibling", !/Afrodite/.test(t2), t2.slice(0, 300));

    await browser.close();
    ok("no page errors on a child's page",
       errors.filter(e => !/Failed to load resource|ERR_/.test(e)).length === 0,
       errors.slice(0, 3).join(" | "));
  }

  // === one child ============================================================
  // Most families. The summary above the list used to repeat the row under it
  // word for word — same name, same school, same number.
  {
    const { browser, page } = await open({
      role: "parent", rpc: { get_my_cards: [TWO[0]] } });
    await page.waitForTimeout(800);
    const t = await text(page);
    ok("one child: the name appears once, not in a summary as well",
       (t.match(/Afrodite Marina Savva/g) || []).length === 1,
       "found " + (t.match(/Afrodite Marina Savva/g) || []).length);
    ok("one child: no combined-total block to expand", !/Due now/i.test(t), t.slice(0, 300));
    ok("one child: the amount is still on the row", /€\d+/.test(t) && /DUE/i.test(t));
    await browser.close();
  }

  // Two owing, and the combined total earns its place again.
  {
    const { browser, page } = await open({ role: "parent", rpc: { get_my_cards: TWO } });
    await page.waitForTimeout(800);
    const t = await text(page);
    ok("two owing: the combined total is back", /Due now/i.test(t));
    ok("and says what it spans rather than naming one of them",
       /across 2 cards/i.test(t), t.slice(0, 300));
    await page.locator('button:has-text("Show details")').first().click();
    await page.waitForTimeout(300);
    ok("with the months behind it", /Show less|Hide details/i.test(await text(page)) ||
       /JAN|FEB|MAR/i.test(await text(page)));
    await browser.close();
  }

  // === a child with two cards ===============================================
  {
    const KIDS = [{ id: "k1", name: "Elena" }];
    const withKid = (c, kid) => ({ ...c, card: { ...c.card, child_id: kid } });
    const CARDS = [
      withKid(card(1, "Elena Georgiou", "Dance School", {}), "k1"),
      withKid(card(2, "Elena G", "Aurora Music School", {}), "k1"),
    ];
    const { browser, page } = await open({
      role: "parent", rpc: { get_my_cards: CARDS, get_my_children: KIDS } });
    await page.waitForTimeout(800);
    const t = await text(page);

    // The accordion is gone: a child with two cards is one row, not a
    // disclosure triangle that unfolds two more in place.
    ok("a child with two cards is a single row", await page.locator(".fam-kid-main").count() === 1);
    ok("summarised by what they have", /2 cards/.test(t), t.slice(0, 300));
    ok("with the two schools counted", /2 schools/.test(t), t.slice(0, 300));

    await row(page, 0).click();
    await page.waitForTimeout(600);
    const t2 = await text(page);
    ok("and both cards are on their page",
       /Dance School/.test(t2) && /Aurora Music School/.test(t2));
    ok("each unlinkable by name",
       /Unlink Elena Georgiou/.test(t2) && /Unlink Elena G\b/.test(t2));
    await browser.close();
  }

  // === the stamp is untouched ===============================================
  // "The stamp should work as it is." It listens on the document for the whole
  // parent portal, so a child's page is still inside it — but that is a claim
  // worth checking rather than assuming, because the page is a new screen.
  {
    const SESSION = {
      ok: true, confirmation: "c0000000-0000-0000-0000-000000000009",
      expires_at: new Date(Date.now() + 60000).toISOString(),
      trigger: "stamp", require_pin: false, business_name: "Dance School",
      type: "Music", accent: "violet", icon: null, year: 2026,
      students: [{ card_id: "card-1", name: "Afrodite Marina Savva", amount: 45, month: "March" }],
    };
    const { browser, page } = await open({
      role: "parent",
      rpc: { get_my_cards: TWO, stamp_trigger_active: { active: true },
             stamp_begin_geometry: SESSION } });
    await page.waitForTimeout(800);
    await row(page, 0).click();
    await page.waitForTimeout(600);
    ok("a child's page is open", /Unlink Afrodite/.test(await text(page)));

    await page.evaluate(() => {
      const pts = [[120, 300], [180, 300], [120, 360], [180, 360], [140, 335]];
      const touches = pts.map((p, i) => new Touch({
        identifier: i, target: document.body, clientX: p[0], clientY: p[1] }));
      document.body.dispatchEvent(new TouchEvent("touchstart", {
        touches, targetTouches: touches, changedTouches: touches,
        bubbles: true, cancelable: true }));
    });
    await page.waitForTimeout(600);

    const fired = await page.evaluate(() => (window.__RPC_CALLS || [])
      .filter(c => c[0] === "stamp_begin_geometry").length);
    ok("THE STAMP STILL FIRES from inside a child's page", fired === 1, "fired " + fired);
    ok("and opens the confirmation over it",
       /Dance School/.test(await text(page)) &&
       /confirm/i.test(await text(page)), (await text(page)).slice(0, 300));
    await browser.close();
  }

  // === nothing linked yet ===================================================
  {
    const { browser, page } = await open({ role: "parent", rpc: { get_my_cards: [] } });
    await page.waitForTimeout(700);
    const t = await text(page);
    ok("an empty portal still says what to do", /Link/i.test(t));
    ok("and shows no page to open", await page.locator(".fam-kid-main").count() === 0);
    await browser.close();
  }

  // === the tab strip itself =================================================
  // A tab that opens on nothing is worse than no tab: it is a promise the page
  // does not keep, and the parent has to tap it to find that out.
  {
    const { browser, page } = await open({
      role: "parent", rpc: { get_my_cards: [TWO[0]] } });   // no notes, no shop, no history
    await page.waitForTimeout(800);
    await row(page, 0).click();
    await page.waitForTimeout(600);
    ok("with nothing else to show, there is no tab bar at all",
       await page.locator(".tab").count() === 0);
    ok("and the card is simply the page", /MONTHS/i.test(await text(page)));
    await browser.close();
  }

  {
    const paid = card(1, "Afrodite Marina Savva", "Dance School", {});
    paid.card.history = [{ n: 1, amount: 32, date: "15/09/2026" },
                         { n: 2, amount: 18, date: "16/09/2026", trigger_source: "stamp" }];
    const { browser, page } = await open({ role: "parent", rpc: { get_my_cards: [paid] } });
    await page.waitForTimeout(800);
    await row(page, 0).click();
    await page.waitForTimeout(600);
    const labels = (await page.locator(".tab").allInnerTexts()).map(x => x.split("\n")[0].trim());
    ok("a card with payments earns a History tab and nothing else",
       labels.join(",") === "Card,History", labels.join(","));

    await tab(page, "History");
    const h = await text(page);
    ok("which lists what was actually handed over", /€32\.00/.test(h) && /€18\.00/.test(h));
    // Newest first: dates are dd/mm/yyyy and sort wrongly as text, so the
    // payment number is what orders them.
    ok("newest first", h.indexOf("€18.00") < h.indexOf("€32.00"), h.slice(0, 200));
    // A payment nobody remembers making needs an explanation attached.
    ok("and says where a payment came from when it was not typed by hand",
       /STAMP/i.test(h), h.slice(0, 200));
    await browser.close();
  }

  // An unread note puts its count on the tab, so it is visible without opening.
  {
    const { browser, page } = await open({
      role: "parent",
      rpc: { get_my_cards: [TWO[0]], get_my_announcements: NOTE, get_my_ann_reads: [] } });
    await page.waitForTimeout(800);
    await row(page, 0).click();
    await page.waitForTimeout(600);
    ok("an unread note is counted on the School tab",
       (await page.locator(".tab-badge").innerText()).trim() === "1");
    await browser.close();
  }

  // === the student portal ===================================================
  // Same three tabs, same reason: this was a card, then where to pay, then
  // every note the school ever posted, then the history underneath all of it.
  {
    const STU = {
      card: { id: "card-1", name: "Andriana", level: { id: "lv1", name: "Begginer" },
              share_code: "AQ3RG0", payments: {},
              history: [{ n: 1, amount: 32, date: "15/09/2026" },
                        { n: 3, amount: 50, date: "16/09/2026", trigger_source: "link" }] },
      business: { name: "Dance School", type: "Other", fee: 50, year: 2026, biz_code: "B1",
                  inactive_months: [], levels: [], custom_card_image: null },
      announcements: [{ id: "a1", title: "Kalimera", body: "Kalimera se ploys",
                        created_at: "2026-09-17T09:00:00Z", target_kind: "all" }],
    };
    const { browser, page, errors } = await open({
      signedOut: true, rpc: { get_student_card: STU } });
    await page.waitForTimeout(700);
    await page.getByText("Quick View").click();
    await page.waitForTimeout(500);
    await page.locator("input.inp").first().fill("AQ3RG0");
    await page.locator("button.btn").first().click();
    await page.waitForTimeout(500);
    await page.locator("input.inp").first().fill("1234");
    await page.locator("button.btn").first().click();
    await page.waitForTimeout(900);

    const labels = (await page.locator(".tab").allInnerTexts()).map(x => x.split("\n")[0].trim());
    ok("the student portal has the same tabs", labels.join(",") === "Card,School,History",
       labels.join(","));

    let t = await text(page);
    ok("it opens on the card", /MONTHS/i.test(t) && /Andriana/.test(t));
    ok("with the notes and the history not stacked under it",
       !/Kalimera se ploys/.test(t) && !/Payment #/.test(t), t.slice(0, 300));

    await tab(page, "School");
    ok("the school's notes are one tap in", /Kalimera se ploys/.test(await text(page)));

    await tab(page, "History");
    t = await text(page);
    ok("and the payment history another", /€50\.00/.test(t) && /€32\.00/.test(t));
    ok("newest first here too", t.indexOf("€50.00") < t.indexOf("€32.00"), t.slice(0, 200));
    ok("with the source of a payment made through the link",
       /PAID ONLINE/i.test(t), t.slice(0, 250));

    await browser.close();
    ok("no page errors in the student portal",
       errors.filter(e => !/Failed to load resource|ERR_/.test(e)).length === 0,
       errors.slice(0, 3).join(" | "));
  }

  // A student with nothing but a card sees no tab bar, same as a parent.
  {
    const { browser, page } = await open({ signedOut: true, rpc: { get_student_card: {
      card: { id: "card-1", name: "Andriana", level: null, share_code: "AQ3RG0",
              payments: {}, history: [] },
      business: { name: "Dance School", type: "Other", fee: 50, year: 2026, biz_code: "B1",
                  inactive_months: [], levels: [], custom_card_image: null },
      announcements: [] } } });
    await page.waitForTimeout(700);
    await page.getByText("Quick View").click();
    await page.waitForTimeout(500);
    await page.locator("input.inp").first().fill("AQ3RG0");
    await page.locator("button.btn").first().click();
    await page.waitForTimeout(500);
    await page.locator("input.inp").first().fill("1234");
    await page.locator("button.btn").first().click();
    await page.waitForTimeout(900);
    ok("a student with only a card gets no tab bar",
       await page.locator(".tab").count() === 0);
    ok("and still sees their card", /Andriana/.test(await text(page)));
    await browser.close();
  }

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
