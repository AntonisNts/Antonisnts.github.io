// The school shop, in a real browser.
//
// Two of these assertions exist because of promises made when the module was
// asked for, and are the reason to run this suite at all:
//
//   "Disabling it for a school should leave no trace in their portal."
//     -> a parent whose school has the shop off must not see a heading, an
//        empty state, or a stray gap. Nothing.
//
//   "Keep the ledgers separate. Shop orders must not affect the monthly fee
//    breakdown."
//     -> placing an order must not move a single month on the card behind it.
//
// The database suite proves both server-side. This proves the screens agree.
const { open, FIXTURES, BIZ_ID } = require("./harness");

let pass = 0, fail = 0;
const ok = (n, c, d) => { c ? (pass++, console.log("  ok   " + n))
                            : (fail++, console.log("  FAIL " + n + (d ? " — " + d : ""))); };
const text = (page) => page.evaluate(() => document.body.innerText);
// The orders screen is filtered and its rows fold. Opening one by the student's
// name is how a school reaches it, so that is how the tests reach it too.
const ordTab = async (page, name) => {
  await page.locator('.tab:has-text("' + name + '")').first().click();
  await page.waitForTimeout(350);
};
// Tapping a row TOGGLES it, so a blind click closes one that is already open.
const openOrder = async (page, who) => {
  const row = page.locator('.ord:has-text("' + who + '")').first();
  if (await row.locator(".ord-open").count() === 0) {
    await row.locator(".ord-main").click();
    await page.waitForTimeout(350);
  }
};
// A child's page is tabbed now. The shop is behind the Shop tab, which only
// appears when that school sells something -- so a missing tab is itself a
// finding, not a locator to work around.
const openShopTab = async (page) => {
  const tab = page.locator('.tab:has-text("Shop")');
  if (await tab.count() === 0) return false;
  await tab.first().click();
  await page.waitForTimeout(400);
  return true;
};
// A real 1x1 PNG. compressImage decodes whatever it is given, so a text file
// pretending to be an image would fail for the wrong reason.
const PNG = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==",
  "base64");
// The months strip is the fee ledger as the parent sees it. Photographed
// before and after an order, it is the separation made checkable.
const months = (s) => (s.match(/\b(JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC)\b/gi) || []).join(",");

const PARENT_CARDS = [{
  card: { id: "card-1", name: "Elena Georgiou", level: { id: "lv1", name: "Beginner", fee: 40 },
          share_code: "SC1001",
          payments: { "2026-01": { paid: true, amount: 40 }, "2026-02": { paid: true, amount: 40 } },
          history: [] },
  business: { name: "Aurora Music School", type: "Music", fee: 45, year: 2026,
              biz_code: "STAMP01", inactive_months: [], levels: [], custom_card_image: null },
}];

const CATALOGUE = [{
  card_id: "card-1", student: "Elena Georgiou", school: "Aurora Music School",
  items: [
    { id: "it1", name: "School Jumper", description: "Navy, embroidered", price: 22.5,
      sizes: ["S", "M", "L"], out_of_stock: false, image_url: null },
    { id: "it2", name: "Ballet Shoes", description: null, price: 18,
      sizes: [], out_of_stock: true, image_url: null },
  ],
}];

(async () => {
  // === the promise: off leaves no trace ====================================
  {
    // shop_catalogue_mine returns nothing at all for a school with the shop
    // off — not an empty catalogue, nothing — so there is no section to draw.
    const { browser, page, errors } = await open({
      role: "parent",
      rpc: { get_my_cards: PARENT_CARDS, shop_catalogue_mine: [], shop_orders_mine: [] } });
    await page.waitForTimeout(700);
    await page.locator(".fam-kid-main").first().click();
    await page.waitForTimeout(500);

    const t = await text(page);
    ok("shop off: no Shop tab at all", await page.locator('.tab:has-text("Shop")').count() === 0);
    ok("shop off: nor the word anywhere in the portal", !/\bShop\b/i.test(t), t.slice(0, 300));
    ok("shop off: no empty state standing in for it", !/Nothing for sale/i.test(t));
    ok("shop off: nothing to order", await page.getByText("Order", { exact: true }).count() === 0);
    await browser.close();
    ok("shop off: no page errors", errors.filter(e => !/Failed to load resource|ERR_/.test(e)).length === 0,
       errors.slice(0, 3).join(" | "));
  }

  // The module must also survive a database that has never seen it. Until the
  // owner runs the migration, every shop RPC 404s — and the portal has to
  // carry on regardless, because everyone else's app is already deployed.
  {
    const { browser, page, errors } = await open({
      role: "parent",
      rpc: { get_my_cards: PARENT_CARDS },
      rpcError: ["shop_catalogue_mine", "shop_orders_mine"] });
    await page.waitForTimeout(700);
    await page.locator(".fam-kid-main").first().click();
    await page.waitForTimeout(500);
    const t = await text(page);
    ok("migration not run: the portal still renders the card", /Elena Georgiou/.test(t));
    ok("migration not run: and shows no shop", !/Nothing for sale/i.test(t));
    ok("migration not run: and offers no Shop tab",
       await page.locator('.tab:has-text("Shop")').count() === 0);
    await browser.close();
  }

  // === the parent's shop ====================================================
  {
    const { browser, page, errors } = await open({
      role: "parent",
      rpc: { get_my_cards: PARENT_CARDS, shop_catalogue_mine: CATALOGUE, shop_orders_mine: [],
             shop_order_place: { ok: true, order: "o1", total: 45 } } });
    await page.waitForTimeout(700);
    await page.locator(".fam-kid-main").first().click();
    await page.waitForTimeout(500);

    ok("the school's shop gets a tab of its own", await openShopTab(page));
    let t = await text(page);
    ok("items are listed under the child they are for",
       /Elena Georgiou/.test(t) && /School Jumper/.test(t));
    ok("with the price as the school set it", /€22\.50/.test(t));
    ok("and the description", /Navy, embroidered/.test(t));
    ok("something with no stock left says so", /Out of stock/i.test(t));
    // A count is the school's business. A parent is told whether they can have
    // it, never how many are on the shelf.
    ok("but never how many are left", !/\bin stock\b/i.test(t), t.slice(0, 400));

    const buttons = await page.getByRole("button", { name: "Order", exact: true }).count();
    ok("only the item still in stock can be ordered", buttons === 1, "found " + buttons);

    // --- the ledgers stay separate ------------------------------------------
    const before = await page.evaluate(() => document.body.innerText);

    await page.getByRole("button", { name: "Order", exact: true }).first().click();
    await page.waitForTimeout(300);
    t = await text(page);
    ok("ordering asks for a size when the item has sizes", /Size/i.test(t) && /How Many/i.test(t));
    ok("and says where it is collected and that fees are elsewhere",
       /collect this at the school/i.test(t) && /separate from your lesson fees/i.test(t));

    await page.locator('button:has-text("Place Order")').first().click();
    await page.waitForTimeout(300);
    ok("a size has to be chosen before the order goes anywhere",
       /Choose a size/i.test(await text(page)));
    let sent = await page.evaluate(() => (window.__RPC_CALLS || []).filter(c => c[0] === "shop_order_place"));
    ok("and nothing was sent", sent.length === 0, "sent " + sent.length);

    await page.locator('.scr-chip:has-text("M")').first().click();
    await page.locator('input[type="number"]').first().fill("2");
    await page.waitForTimeout(200);
    ok("the total follows the quantity", /Total €45\.00/.test(await text(page)));

    await page.locator('button:has-text("Place Order")').first().click();
    await page.waitForTimeout(500);
    sent = await page.evaluate(() => (window.__RPC_CALLS || []).find(c => c[0] === "shop_order_place"));
    ok("the order carries the card, the item, the size and the quantity",
       sent && sent[1].p_card_id === "card-1" && sent[1].p_lines.length === 1
       && sent[1].p_lines[0].item_id === "it1" && sent[1].p_lines[0].size === "M"
       && sent[1].p_lines[0].qty === 2,
       JSON.stringify(sent && sent[1]));
    // The price is never in it. A total the page computed is a total the page
    // could choose; the database prices every line from its own table.
    ok("and no price — the database does the arithmetic",
       sent && JSON.stringify(sent[1]).indexOf("price") === -1, JSON.stringify(sent && sent[1]));

    ok("the parent is told what happens next",
       /will let you know when it is ready to collect/i.test(await text(page)));

    const after = await page.evaluate(() => document.body.innerText);
    ok("THE LEDGERS STAY SEPARATE: the months on the card did not move",
       months(before) === months(after), months(before) + " vs " + months(after));
    ok("and no fee RPC was called by ordering",
       (await page.evaluate(() => (window.__RPC_CALLS || []).map(c => c[0])))
         .every(n => !/stamp_apply_payment|payment_claim_create|save_card/.test(n)));

    await browser.close();
    ok("no page errors in the parent's shop", errors.filter(e => !/Failed to load resource|ERR_/.test(e)).length === 0,
       errors.slice(0, 3).join(" | "));
  }

  // --- sold out between opening the page and pressing the button ------------
  {
    const { browser, page } = await open({
      role: "parent",
      rpc: { get_my_cards: PARENT_CARDS, shop_catalogue_mine: CATALOGUE, shop_orders_mine: [],
             shop_order_place: { error: "out_of_stock" } } });
    await page.waitForTimeout(700);
    await page.locator(".fam-kid-main").first().click();
    await page.waitForTimeout(500);
    await openShopTab(page);
    await page.getByRole("button", { name: "Order", exact: true }).first().click();
    await page.waitForTimeout(300);
    await page.locator('.scr-chip:has-text("S")').first().click();
    await page.locator('button:has-text("Place Order")').first().click();
    await page.waitForTimeout(400);
    ok("a sold-out answer is said plainly, not as an error code",
       /just sold out/i.test(await text(page)));
    await browser.close();
  }

  // --- the parent's own orders ----------------------------------------------
  {
    const MINE = [
      { id: "o1", card_id: "card-1", student: "Elena Georgiou", status: "ready",
        payment_status: "unpaid", total: 45, created_at: "2026-09-10T10:00:00Z",
        lines: [{ name: "School Jumper", size: "M", qty: 2, line_total: 45 }] },
      { id: "o2", card_id: "card-1", student: "Elena Georgiou", status: "new",
        payment_status: "claimed", claim_amount: 18, claim_date: "2026-09-12", total: 18,
        created_at: "2026-09-12T10:00:00Z",
        lines: [{ name: "Ballet Shoes", size: null, qty: 1, line_total: 18 }] },
    ];
    const { browser, page } = await open({
      role: "parent",
      rpc: { get_my_cards: PARENT_CARDS, shop_catalogue_mine: CATALOGUE, shop_orders_mine: MINE,
             payment_links_mine: [{ card_id: "card-1", link: "https://revolut.me/antonis", name: "Revolut" }],
             shop_order_claim_paid: { ok: true } } });
    await page.waitForTimeout(700);
    await page.locator(".fam-kid-main").first().click();
    await page.waitForTimeout(500);
    await openShopTab(page);

    // The fee card's own pay-online panel is on the Card tab and says almost
    // the same words, so everything below is scoped to the order it belongs to.
    const o1 = page.locator(".shop-my-order").first();

    let t = await text(page);
    ok("the parent can see what they have ordered", /Your Orders/i.test(t) && /2 × School Jumper \(M\)/.test(t));
    ok("a ready order says it is ready to collect", /Ready to collect/i.test(t));

    // The claim wording is load-bearing in exactly the way it is on the fee
    // side: a parent who reads "told the school" as "done" will be surprised.
    ok("a claimed order says the parent told the school", /told the school you paid €18\.00/i.test(t));
    ok("and says in as many words that it is NOT paid yet",
       /Not marked paid yet/i.test(t), t.slice(0, 400));

    // Two steps, same as the fee side: the link opens first.
    ok("an unpaid order offers the school's link", /Pay online · Revolut/i.test(t));
    ok("with nothing to claim before the link has been opened",
       await o1.getByText("I've paid", { exact: true }).count() === 0);

    const href = await o1.locator("a").first().getAttribute("href");
    ok("pointing at the school's own link", href === "https://revolut.me/antonis", String(href));

    const fees = await page.evaluate(() => document.body.innerText);
    await o1.locator("a").first().click();
    await page.waitForTimeout(300);
    ok("after opening it, the parent can say they paid",
       await o1.getByText("I've paid", { exact: true }).count() === 1);

    await o1.locator('button:has-text("I\'ve paid")').first().click();
    await page.waitForTimeout(300);
    t = await text(page);
    ok("the form is prefilled with what the order costs", /45\.00/.test(
       await o1.locator('input[type="number"]').first().inputValue()));
    ok("and says plainly that this marks nothing paid",
       /does not mark anything paid/i.test(t), t.slice(0, 300));

    await o1.locator('button:has-text("Tell The School")').first().click();
    await page.waitForTimeout(500);
    const claimed = await page.evaluate(() => (window.__RPC_CALLS || []).find(c => c[0] === "shop_order_claim_paid"));
    ok("the claim is against the ORDER, not against the fee ledger",
       claimed && claimed[1].p_order_id === "o1" && claimed[1].p_amount === 45,
       JSON.stringify(claimed && claimed[1]));
    ok("and it did not go through payment_claim_create, which moves months",
       !(await page.evaluate(() => (window.__RPC_CALLS || []).some(c => c[0] === "payment_claim_create"))));
    ok("the months are untouched by a kit claim too",
       months(fees) === months(await page.evaluate(() => document.body.innerText)));

    await browser.close();
  }

  // === the owner's items screen =============================================
  {
    const ITEMS = { ok: true, enabled: false, items: [
      { id: "it1", name: "School Jumper", description: "Navy", price: 22.5,
        sizes: ["S","M","L"], stock: 4, image_url: null, archived: false },
      { id: "it2", name: "Ballet Shoes", description: null, price: 18,
        sizes: [], stock: 0, image_url: null, archived: false },
      { id: "it3", name: "Old Tracksuit", description: null, price: 30,
        sizes: [], stock: null, image_url: null, archived: true },
    ] };
    const { browser, page, errors } = await open({
      rpc: { shop_items_list: ITEMS, shop_settings_set: { ok: true, enabled: true },
             shop_item_save: { ok: true }, shop_item_archive: { ok: true } } });
    await page.waitForTimeout(600);
    await page.locator(".dash-gear").first().click();
    await page.waitForTimeout(350);
    await page.locator(".set-ov").getByText("Items", { exact: true }).locator("visible=true").first().click();
    await page.waitForTimeout(600);

    // sweep.js walks the other settings screens for this; the shop stays out of
    // its list so that removing the module never means editing a test that is
    // not the module's own. A screen that uses the accent classes without
    // publishing --accent falls back to the :root default and looks wrong for
    // every school that picked a colour.
    const skin = await page.evaluate(() => {
      const r = document.querySelector(".page,.reg-page,.dash-shell");
      return { cls: r ? r.className : null, published: r ? r.style.getPropertyValue("--accent") : "",
               consumers: document.querySelectorAll(".scr-lbl,.scr-chip.on,.scr-btn.primary").length };
    });
    ok("the items screen opens on the shared skin", /\bscr\b/.test(skin.cls || ""), "root=" + skin.cls);
    ok("and publishes --accent for the accent classes it uses",
       skin.consumers > 0 && !!skin.published, JSON.stringify(skin));

    let t = await text(page);
    ok("the owner is told what the shop is for", /collect at the school/i.test(t) && /nothing is posted/i.test(t));
    ok("off by default, and it says what off means",
       /Off\. Your parents see nothing at all/i.test(t), t.slice(0, 500));
    ok("items are listed with price and sizes", /School Jumper/.test(t) && /€22\.50/.test(t) && /Sizes: S, M, L/.test(t));
    // null stock and 0 stock are different facts and must read differently.
    ok("a counted item shows the count", /4 in stock/.test(t));
    ok("a counted item with none left says out of stock", /out of stock/i.test(t));
    ok("an uncounted item says it is not being counted", /stock not counted/i.test(t));
    ok("an archived item is shown, marked, not hidden", /Old Tracksuit · archived/.test(t));
    ok("and can be restored", await page.getByRole("button", { name: "Restore" }).count() === 1);

    await page.locator('button:has-text("Switch Shop On")').first().click();
    await page.waitForTimeout(400);
    ok("switching on says when parents will see it",
       /Parents will see it next time/i.test(await text(page)));
    const set = await page.evaluate(() => (window.__RPC_CALLS || []).find(c => c[0] === "shop_settings_set"));
    ok("the switch sends the new state", set && set[1].p_enabled === true, JSON.stringify(set && set[1]));

    // --- adding an item -------------------------------------------------------
    await page.locator('button:has-text("+ Add Item")').first().click();
    await page.waitForTimeout(300);
    await page.locator('button:has-text("Save Item")').first().click();
    await page.waitForTimeout(300);
    ok("an item with no name is refused before the database sees it",
       /Give the item a name/i.test(await text(page)));
    let saves = await page.evaluate(() => (window.__RPC_CALLS || []).filter(c => c[0] === "shop_item_save").length);
    ok("and nothing was sent", saves === 0, "sent " + saves);

    await page.locator('input[placeholder="e.g. School Jumper"]').fill("PE Shorts");
    await page.locator('button:has-text("Save Item")').first().click();
    await page.waitForTimeout(300);
    ok("nor one with no price", /Give the item a price/i.test(await text(page)));

    await page.locator('input[placeholder="0"]').fill("12.5");
    await page.locator('input[placeholder="S, M, L"]').fill("8, 10, 12");
    await page.locator('input[placeholder="not counted"]').fill("20");
    await page.locator('button:has-text("Save Item")').first().click();
    await page.waitForTimeout(400);
    const saved = await page.evaluate(() => (window.__RPC_CALLS || []).find(c => c[0] === "shop_item_save"));
    ok("sizes typed as a list arrive as a list",
       saved && JSON.stringify(saved[1].p_sizes) === '["8","10","12"]', JSON.stringify(saved && saved[1].p_sizes));
    ok("with the price and the stock count",
       saved && saved[1].p_price === 12.5 && saved[1].p_stock === 20, JSON.stringify(saved && saved[1]));

    await browser.close();
    ok("no page errors on the items screen", errors.filter(e => !/Failed to load resource|ERR_/.test(e)).length === 0,
       errors.slice(0, 3).join(" | "));
  }

  // --- blank stock means "not counted", not zero ----------------------------
  {
    const { browser, page } = await open({
      rpc: { shop_items_list: { ok: true, enabled: true, items: [] }, shop_item_save: { ok: true } } });
    await page.waitForTimeout(600);
    await page.locator(".dash-gear").first().click();
    await page.waitForTimeout(350);
    await page.locator(".set-ov").getByText("Items", { exact: true }).locator("visible=true").first().click();
    await page.waitForTimeout(600);
    await page.locator('button:has-text("+ Add Item")').first().click();
    await page.waitForTimeout(300);
    await page.locator('input[placeholder="e.g. School Jumper"]').fill("Water Bottle");
    await page.locator('input[placeholder="0"]').fill("5");
    await page.locator('button:has-text("Save Item")').first().click();
    await page.waitForTimeout(400);
    const s = await page.evaluate(() => (window.__RPC_CALLS || []).find(c => c[0] === "shop_item_save"));
    ok("a blank stock box sends null, which is 'not counting', not 'none left'",
       s && s[1].p_stock === null, JSON.stringify(s && s[1]));
    ok("and an empty size box sends an empty list", s && JSON.stringify(s[1].p_sizes) === "[]");
    await browser.close();
  }

  // --- photographs ----------------------------------------------------------
  // Was a box asking for an https:// link, which meant getting the picture
  // onto the internet somewhere else first. It is a file now.
  {
    const ITEMS = { ok: true, enabled: true, items: [
      { id: "it1", name: "School Jumper", description: null, price: 22.5, sizes: [],
        stock: null, image_url: null, archived: false }] };
    const { browser, page, errors } = await open({
      rpc: { shop_items_list: ITEMS, shop_item_save: { ok: true } } });
    await page.waitForTimeout(600);
    await page.locator(".dash-gear").first().click();
    await page.waitForTimeout(350);
    await page.locator(".set-ov").getByText("Items", { exact: true }).locator("visible=true").first().click();
    await page.waitForTimeout(600);
    await page.locator('button:has-text("+ Add Item")').first().click();
    await page.waitForTimeout(300);

    let t = await text(page);
    ok("the form asks for a photo, not a link", /Take Or Choose A Photo/i.test(t) &&
       !/https:\/\//.test(t), t.slice(0, 500));
    ok("and says what happens without one", /No photo/i.test(t));
    ok("there is no url box left to paste into",
       await page.locator('input[type="url"]').count() === 0);

    await page.locator('input[placeholder="e.g. School Jumper"]').fill("PE Shorts");
    await page.locator('input[placeholder="0"]').fill("12");
    await page.locator('input[type="file"]').setInputFiles({
      name: "shorts.png", mimeType: "image/png", buffer: PNG });
    await page.waitForTimeout(400);
    ok("the chosen photo is shown before it is saved",
       await page.locator('img[src^="blob:"]').count() === 1);
    ok("and nothing has been uploaded yet — abandoning the form uploads nothing",
       (await page.evaluate(() => (window.__UPLOADS || []).length)) === 0);

    await page.locator('button:has-text("Save Item")').first().click();
    await page.waitForTimeout(700);

    const up = await page.evaluate(() => (window.__UPLOADS || [])[0]);
    ok("saving puts it in the shop's own bucket", up && up.bucket === "shop-images",
       JSON.stringify(up));
    ok("under the school's own folder, which is what the policy checks",
       up && up.path.indexOf(BIZ_ID + "/") === 0, JSON.stringify(up));
    // A phone photograph is several megabytes and nobody needs that to look at
    // a jumper. compressImage re-encodes it as JPEG first.
    ok("re-encoded rather than sent as it came off the phone",
       up && up.type === "image/jpeg" && /\.jpg$/.test(up.path), JSON.stringify(up));

    const saved = await page.evaluate(() => (window.__RPC_CALLS || [])
      .find(c => c[0] === "shop_item_save"));
    ok("and the item points at the uploaded file",
       saved && /\/shop-images\//.test(saved[1].p_image_url || ""),
       JSON.stringify(saved && saved[1].p_image_url));

    await browser.close();
    ok("no page errors attaching a photo",
       errors.filter(e => !/Failed to load resource|ERR_/.test(e)).length === 0,
       errors.slice(0, 3).join(" | "));
  }

  // --- replacing and removing one ------------------------------------------
  {
    const URL0 = "https://x.supabase.co/storage/v1/object/public/shop-images/" + BIZ_ID + "/item-1.jpg";
    const ITEMS = { ok: true, enabled: true, items: [
      { id: "it1", name: "School Jumper", description: null, price: 22.5, sizes: [],
        stock: null, image_url: URL0, archived: false }] };
    const { browser, page } = await open({
      rpc: { shop_items_list: ITEMS, shop_item_save: { ok: true } } });
    await page.waitForTimeout(600);
    await page.locator(".dash-gear").first().click();
    await page.waitForTimeout(350);
    await page.locator(".set-ov").getByText("Items", { exact: true }).locator("visible=true").first().click();
    await page.waitForTimeout(600);

    ok("an item with a photo shows it in the list",
       await page.locator('img[src="' + URL0 + '"]').count() >= 1);

    await page.locator('button:has-text("Edit")').first().click();
    await page.waitForTimeout(300);
    ok("editing shows the photo it already has", /Change Photo/i.test(await text(page)));

    await page.locator('input[type="file"]').setInputFiles({
      name: "new.png", mimeType: "image/png", buffer: PNG });
    await page.waitForTimeout(300);
    await page.locator('button:has-text("Save Item")').first().click();
    await page.waitForTimeout(700);

    const up = await page.evaluate(() => (window.__UPLOADS || []));
    const rm = await page.evaluate(() => (window.__REMOVED || []));
    ok("replacing uploads the new one", up.length === 1);
    ok("and deletes the old one it replaced",
       rm.length === 1 && rm[0].path === BIZ_ID + "/item-1.jpg", JSON.stringify(rm));
    // Order matters: a replacement that failed halfway must not have deleted
    // the picture it was replacing, so the new one goes up first.
    const ops = await page.evaluate(() => (window.__STORAGE_OPS || []));
    ok("and the new one went up BEFORE the old one was deleted",
       ops.length === 2 && /^upload:/.test(ops[0]) && /^remove:/.test(ops[1]),
       JSON.stringify(ops));

    await browser.close();
  }

  {
    const URL0 = "https://x.supabase.co/storage/v1/object/public/shop-images/" + BIZ_ID + "/item-9.jpg";
    const { browser, page } = await open({
      rpc: { shop_items_list: { ok: true, enabled: true, items: [
               { id: "it1", name: "Cap", description: null, price: 9, sizes: [],
                 stock: null, image_url: URL0, archived: false }] },
             shop_item_save: { ok: true } } });
    await page.waitForTimeout(600);
    await page.locator(".dash-gear").first().click();
    await page.waitForTimeout(350);
    await page.locator(".set-ov").getByText("Items", { exact: true }).locator("visible=true").first().click();
    await page.waitForTimeout(600);
    await page.locator('button:has-text("Edit")').first().click();
    await page.waitForTimeout(300);
    await page.locator('button:has-text("Remove Photo")').first().click();
    await page.waitForTimeout(300);
    ok("removing it offers to add one again", /Take Or Choose A Photo/i.test(await text(page)));
    await page.locator('button:has-text("Save Item")').first().click();
    await page.waitForTimeout(700);
    const saved = await page.evaluate(() => (window.__RPC_CALLS || [])
      .find(c => c[0] === "shop_item_save"));
    ok("and the item is saved with no picture", saved && saved[1].p_image_url === null,
       JSON.stringify(saved && saved[1].p_image_url));
    const rm = await page.evaluate(() => (window.__REMOVED || []));
    ok("with the file deleted rather than left behind",
       rm.length === 1 && rm[0].path === BIZ_ID + "/item-9.jpg", JSON.stringify(rm));
    await browser.close();
  }

  // --- an upload that fails must not half-save ------------------------------
  {
    const { browser, page } = await open({
      rpc: { shop_items_list: { ok: true, enabled: true, items: [] },
             shop_item_save: { ok: true } } });
    await page.waitForTimeout(600);
    await page.evaluate(() => {
      const real = window.__MOCK_SB.storage.from;
      window.__MOCK_SB.storage.from = (b) => {
        const o = real(b);
        return { ...o, upload: async () => ({ data: null, error: { message: "Bucket not found" } }) };
      };
    });
    await page.locator(".dash-gear").first().click();
    await page.waitForTimeout(350);
    await page.locator(".set-ov").getByText("Items", { exact: true }).locator("visible=true").first().click();
    await page.waitForTimeout(600);
    await page.locator('button:has-text("+ Add Item")').first().click();
    await page.waitForTimeout(300);
    await page.locator('input[placeholder="e.g. School Jumper"]').fill("Cap");
    await page.locator('input[placeholder="0"]').fill("9");
    await page.locator('input[type="file"]').setInputFiles({
      name: "c.png", mimeType: "image/png", buffer: PNG });
    await page.waitForTimeout(300);
    await page.locator('button:has-text("Save Item")').first().click();
    await page.waitForTimeout(700);
    ok("a failed upload says so in English, and names the likely cause",
       /picture would not upload/i.test(await text(page)) &&
       /shop-images/.test(await text(page)));
    const saved = await page.evaluate(() => (window.__RPC_CALLS || [])
      .filter(c => c[0] === "shop_item_save").length);
    ok("and the item is NOT written pointing at a picture that is not there",
       saved === 0, "saved " + saved);
    await browser.close();
  }

  // --- the parent sees it ---------------------------------------------------
  {
    const PIC = "https://x.supabase.co/storage/v1/object/public/shop-images/b/jumper.jpg";
    const CAT = [{ card_id: "card-1", student: "Elena Georgiou", school: "Aurora Music School",
      items: [{ id: "it1", name: "School Jumper", description: "Navy", price: 22.5,
                sizes: ["S","M"], out_of_stock: false, image_url: PIC }] }];
    const { browser, page } = await open({
      role: "parent",
      rpc: { get_my_cards: PARENT_CARDS, shop_catalogue_mine: CAT, shop_orders_mine: [] } });
    await page.waitForTimeout(700);
    await page.locator(".fam-kid-main").first().click();
    await page.waitForTimeout(600);
    await openShopTab(page);
    ok("the photo reaches the parent's shop", await page.locator('img[src="' + PIC + '"]').count() >= 1);

    await page.getByRole("button", { name: "Order", exact: true }).first().click();
    await page.waitForTimeout(300);
    ok("and is on the order dialog, so they see what they are buying",
       await page.locator('.scr-card img[src="' + PIC + '"]').count() >= 1);
    // A uniform photographed head to toe loses the head and the feet to
    // `cover` -- the two ends that say what it is.
    const fit = await page.locator('img[src="' + PIC + '"]').first()
      .evaluate(el => getComputedStyle(el).objectFit);
    ok("shown whole rather than cropped to fill", fit === "contain", fit);

    // And larger still on a tap, because a small `contain` box is a small
    // picture -- the point of a photo of a uniform is to see the uniform.
    // The order dialog is still open over the item card.
    await page.locator('button:has-text("Cancel")').last().click();
    await page.waitForTimeout(300);

    await page.locator('.scr-card img[src="' + PIC + '"]').first().click();
    await page.waitForTimeout(300);
    ok("tapping it opens the whole picture",
       await page.locator(".photo-lightbox").count() === 1);
    // The fixture URL never loads, so a measured width says nothing. What the
    // lightbox promises is the constraint: as big as the screen allows, whole.
    const big = await page.locator('.photo-lightbox img').first()
      .evaluate(el => { const c = getComputedStyle(el);
        return { maxW: c.maxWidth, maxH: c.maxHeight, fit: c.objectFit,
                 overlay: getComputedStyle(el.parentElement).position }; });
    ok("as large as the screen allows, and still whole",
       big.maxW === "100%" && big.maxH === "100%" && big.fit === "contain"
       && big.overlay === "fixed", JSON.stringify(big));
    await page.locator(".photo-lightbox").click();
    await page.waitForTimeout(250);
    ok("and closes again on a tap", await page.locator(".photo-lightbox").count() === 0);
    await browser.close();
  }

  // --- the owner can see what they published --------------------------------
  {
    const URL0 = "https://x.supabase.co/storage/v1/object/public/shop-images/" + BIZ_ID + "/item-7.jpg";
    const { browser, page } = await open({
      rpc: { shop_items_list: { ok: true, enabled: true, items: [
        { id: "it1", name: "Uniform", description: null, price: 50, sizes: [],
          stock: null, image_url: URL0, archived: false }] } } });
    await page.waitForTimeout(600);
    await page.locator(".dash-gear").first().click();
    await page.waitForTimeout(350);
    await page.locator(".set-ov").getByText("Items", { exact: true }).locator("visible=true").first().click();
    await page.waitForTimeout(600);

    // A 56px square is an identifier, not the picture, so cropping it is right.
    const thumb = await page.locator('img[src="' + URL0 + '"]').first()
      .evaluate(el => ({ fit: getComputedStyle(el).objectFit,
                         w: Math.round(el.getBoundingClientRect().width) }));
    ok("the owner's list shows a square thumbnail", thumb.fit === "cover" && thumb.w === 56,
       JSON.stringify(thumb));

    await page.locator('img[src="' + URL0 + '"]').first().click();
    await page.waitForTimeout(300);
    ok("and the whole picture on a tap", await page.locator(".photo-lightbox").count() === 1);

    await page.locator(".photo-lightbox").click();
    await page.waitForTimeout(250);
    await page.locator('button:has-text("Edit")').first().click();
    await page.waitForTimeout(300);
    // The preview is what they are about to publish; cropping it would hide
    // exactly what they need to check.
    // Scoped to the form: the list's 56px thumbnail is on screen too, and it
    // is meant to be cropped.
    const prev = await page.locator('.scr-card:has-text("Edit Item") img').first()
      .evaluate(el => getComputedStyle(el).objectFit);
    ok("and the edit preview is not cropped either", prev === "contain", prev);
    await browser.close();
  }

  // === the owner's order queue ==============================================
  {
    const QUEUE = { ok: true, enabled: true, owed: 63,
      orders: [
        { id: "o1", student: "Elena Georgiou", status: "new", payment_status: "unpaid",
          total: 45, ordered_by: "mum@example.com", note: "Collecting Friday",
          paid_via: null, created_at: "2026-09-10T10:00:00Z",
          claim_amount: null, claim_date: null, claim_ref: null,
          lines: [{ name: "School Jumper", size: "M", qty: 2, line_total: 45 }] },
        { id: "o2", student: "Andreas Pavlou", status: "ready", payment_status: "claimed",
          total: 18, ordered_by: "dad@example.com", note: null, paid_via: null,
          created_at: "2026-09-11T10:00:00Z",
          claim_amount: 18, claim_date: "2026-09-12", claim_ref: "REV-4410",
          lines: [{ name: "Ballet Shoes", size: null, qty: 1, line_total: 18 }] },
        { id: "o3", student: "Maria Christodoulou", status: "collected", payment_status: "paid",
          total: 30, ordered_by: "m@example.com", note: null, paid_via: "manual",
          created_at: "2026-09-01T10:00:00Z",
          claim_amount: null, claim_date: null, claim_ref: null,
          lines: [{ name: "Tracksuit", size: null, qty: 1, line_total: 30 }] },
      ] };

    const { browser, page, errors } = await open({
      rpc: { shop_orders_queue: QUEUE, shop_order_set_status: { ok: true },
             shop_order_mark_paid_owner: { ok: true }, shop_order_unmark_paid: { ok: true } } });
    await page.waitForTimeout(600);

    // The badge on the settings row: new orders and claims waiting on a look.
    await page.locator(".dash-gear").first().click();
    await page.waitForTimeout(350);
    const row = await page.locator(".set-ov").getByText("Shop Orders", { exact: true })
      .locator("xpath=../..").innerText();
    ok("the settings row counts what is waiting on the owner", /2/.test(row), row);

    await page.locator(".set-ov").getByText("Shop Orders", { exact: true }).locator("visible=true").first().click();
    await page.waitForTimeout(600);

    const skin = await page.evaluate(() => {
      const r = document.querySelector(".page,.reg-page,.dash-shell");
      return { cls: r ? r.className : null, published: r ? r.style.getPropertyValue("--accent") : "" };
    });
    ok("the orders screen opens on the shared skin and publishes --accent",
       /\bscr\b/.test(skin.cls || "") && !!skin.published, JSON.stringify(skin));

    // Nine orders were nine tall cards each with three full-width buttons.
    // The three questions a school asks are different questions.
    const tabs = (await page.locator(".tab").allInnerTexts()).map(x => x.split("\n")[0].trim());
    ok("the orders are sliced by what the school has to do",
       tabs.join(",") === "To do,Unpaid,Done", tabs.join(","));
    ok("and it opens on what is waiting on them",
       await page.locator('.tab.on:has-text("To do")').count() === 1);

    let t = await text(page);
    ok("THE LEDGERS STAY SEPARATE: the kit total says so on its face",
       /Owed For Kit/i.test(t) && /€63\.00/.test(t) && /separate from lesson fees/i.test(t), t.slice(0, 300));
    ok("and the screen says kit never reaches what a student owes for the month",
       /nothing here appears in what a student owes for the month/i.test(t));

    ok("orders are listed by student with their lines",
       /Elena Georgiou/.test(t) && /2 × School Jumper \(M\)/.test(t));
    // innerText reflects text-transform, so these badges arrive shouting.
    ok("an unpaid order reads as unpaid", /Unpaid/i.test(t));
    ok("a claim reads as a claim, not as payment", /Says paid/i.test(t));

    // The detail -- the note, what they said they paid, the reference -- is
    // behind the row. The list is for reading; acting on one order is a
    // deliberate second step.
    await openOrder(page, "Elena Georgiou");
    ok("opening a row shows the parent's note", /Collecting Friday/.test(await text(page)));

    await openOrder(page, "Andreas Pavlou");
    t = await text(page);
    ok("and what they said they paid, beside the button that accepts it",
       /Says they paid €18\.00/i.test(t), t.slice(0, 300));
    ok("with the reference they gave", /REV-4410/.test(t));

    await ordTab(page, "Done");
    ok("a settled one says how it was settled", /Paid · manual/i.test(await text(page)));

    await ordTab(page, "To do");
    await openOrder(page, "Elena Georgiou");
    await page.locator('button:has-text("Mark ready")').first().click();
    await page.waitForTimeout(400);
    let call = await page.evaluate(() => (window.__RPC_CALLS || []).find(c => c[0] === "shop_order_set_status"));
    ok("a new order moves to ready", call && call[1].p_order_id === "o1" && call[1].p_status === "ready",
       JSON.stringify(call && call[1]));

    await openOrder(page, "Elena Georgiou");
    await page.locator('button:has-text("Mark Paid")').first().click();
    await page.waitForTimeout(400);
    call = await page.evaluate(() => (window.__RPC_CALLS || []).find(c => c[0] === "shop_order_mark_paid_owner"));
    ok("marking paid by hand is recorded as done by hand",
       call && call[1].p_order_id === "o1" && call[1].p_via === "manual", JSON.stringify(call && call[1]));

    await openOrder(page, "Andreas Pavlou");
    await page.locator('button:has-text("Confirm Payment")').first().click();
    await page.waitForTimeout(400);
    call = await page.evaluate(() => (window.__RPC_CALLS || [])
      .filter(c => c[0] === "shop_order_mark_paid_owner").pop());
    // Same seam, different trigger — which is the whole point of the seam.
    ok("confirming a claim settles it through the SAME function, marked as the link",
       call && call[1].p_order_id === "o2" && call[1].p_via === "link", JSON.stringify(call && call[1]));

    await browser.close();
    ok("no page errors in the queue", errors.filter(e => !/Failed to load resource|ERR_/.test(e)).length === 0,
       errors.slice(0, 3).join(" | "));
  }

  // --- cancelling, and undoing a payment ------------------------------------
  {
    const { browser, page } = await open({
      rpc: { shop_orders_queue: { ok: true, enabled: true, owed: 45, orders: [
               { id: "o1", student: "Elena Georgiou", status: "new", payment_status: "paid",
                 total: 45, ordered_by: "mum@example.com", note: null, paid_via: "manual",
                 created_at: "2026-09-10T10:00:00Z",
                 claim_amount: null, claim_date: null, claim_ref: null,
                 lines: [{ name: "School Jumper", size: "M", qty: 2, line_total: 45 }] }] },
             shop_order_unmark_paid: { ok: true }, shop_order_set_status: { ok: true } } });
    await page.waitForTimeout(600);
    await page.locator(".dash-gear").first().click();
    await page.waitForTimeout(350);
    await page.locator(".set-ov").getByText("Shop Orders", { exact: true }).locator("visible=true").first().click();
    await page.waitForTimeout(600);

    await openOrder(page, "Elena Georgiou");
    ok("a paid order offers no second Mark Paid",
       await page.getByRole("button", { name: "Mark Paid" }).count() === 0);
    await page.locator('button:has-text("Undo Paid")').first().click();
    await page.waitForTimeout(400);
    let call = await page.evaluate(() => (window.__RPC_CALLS || []).find(c => c[0] === "shop_order_unmark_paid"));
    ok("a payment marked in error can be taken back", call && call[1].p_order_id === "o1");
    ok("and the owner is told what it means", /Set back to unpaid/i.test(await text(page)));

    await page.locator('button:has-text("Cancel")').first().click();
    await page.waitForTimeout(400);
    call = await page.evaluate(() => (window.__RPC_CALLS || [])
      .filter(c => c[0] === "shop_order_set_status").pop());
    ok("cancelling says so", call && call[1].p_status === "cancelled", JSON.stringify(call && call[1]));
    ok("and says the stock went back", /counted stock has gone back/i.test(await text(page)));

    // Destructive stays semantic red. Cancel is the only red thing here.
    const danger = await page.locator(".scr-btn.danger").allInnerTexts();
    ok("only the destructive action is red", danger.join(",") === "Cancel", danger.join(","));
    await browser.close();
  }

  // --- already paid, from two places at once --------------------------------
  {
    const { browser, page } = await open({
      rpc: { shop_orders_queue: { ok: true, enabled: true, owed: 45, orders: [
               { id: "o1", student: "Elena Georgiou", status: "new", payment_status: "unpaid",
                 total: 45, ordered_by: "mum@example.com", note: null, paid_via: null,
                 created_at: "2026-09-10T10:00:00Z",
                 claim_amount: null, claim_date: null, claim_ref: null, lines: [] }] },
             shop_order_mark_paid_owner: { error: "already_paid" } } });
    await page.waitForTimeout(600);
    await page.locator(".dash-gear").first().click();
    await page.waitForTimeout(350);
    await page.locator(".set-ov").getByText("Shop Orders", { exact: true }).locator("visible=true").first().click();
    await page.waitForTimeout(600);
    await openOrder(page, "Elena Georgiou");
    await page.locator('button:has-text("Mark Paid")').first().click();
    await page.waitForTimeout(400);
    ok("the seam's refusal to settle twice is said in English",
       /already marked paid/i.test(await text(page)));
    await browser.close();
  }

  // === removability =========================================================
  // Not a screen — the promise that the module can be taken back out. If these
  // markers drift, the removal instructions in migration-shop.sql stop being
  // true, and nobody finds out until they try.
  {
    const fs = require("fs");
    const src = fs.readFileSync(__dirname + "/../index.html", "utf8");
    const begin = src.indexOf("SHOP MODULE — BEGIN");
    const end   = src.indexOf("SHOP MODULE — END");
    ok("the module is one contiguous block", begin > 0 && end > begin);

    const block = src.slice(begin, end);
    const outside = src.slice(0, begin) + src.slice(end);
    const mounts = (outside.match(/SHOP MODULE mount/g) || []).length;
    ok("with a known number of mounts outside it", mounts === 8, "found " + mounts);

    // The removal instructions say "delete the block and every marked line".
    // Do exactly that, then look at what is left: anything still naming the
    // module is a reference the instructions would have left dangling.
    const stripped = outside.split("\n").filter(l => !/SHOP MODULE mount/.test(l)).join("\n");
    const left = stripped.split("\n").filter(l =>
      /PgShopItems|PgShopOrders|ShopPanel|useShopPending|useShopCards|shopCards|shopPending|shopOn|stuShop|setStuShop|onShopItems|onShopOrders|view==="shop/.test(l));
    ok("after the documented removal, nothing calls the module",
       !/PgShopItems|<ShopPanel|useShopPending|useShopCards|stuShop|view==="shop/.test(stripped),
       left.slice(0, 2).map(l => l.slice(0, 140)).join(" // "));

    // What does survive: two handler props on PgDashboard. Both name only
    // things the removal leaves standing, so neither can throw. Anything ELSE
    // surviving is a reference the instructions would have left dangling.
    const inert = left.filter(l =>
      !/function PgDashboard\(/.test(l) && !/view==="dashboard"/.test(l));
    ok("and what survives is only the dashboard's two handler props",
       inert.length === 0, inert.slice(0, 2).map(l => l.slice(0, 140)).join(" // "));
    // The surviving names must not reach anything the removal deleted -- a
    // prop reading shopPending, say, would be a ReferenceError on load.
    ok("which reach nothing the removal took away",
       !/shopPending|loadShopPending|setShopPending|shopCards|shopOn|stuShop/.test(stripped),
       left.slice(0, 2).map(l => l.slice(0, 140)).join(" // "));
    ok("and the block's own instructions describe them",
       /neither refers to anything the removal deletes/i.test(block.replace(/\n\s*/g, " ")));

    ok("the block carries its own removal instructions",
       /delete this\s+block and every line marked "SHOP MODULE mount"/.test(block.replace(/\n\s*/g, " ")));

    // And the part no amount of reading proves: do the removal for real, on a
    // copy, and boot what is left. A dangling reference is a blank screen for
    // every school, so this is the assertion that matters.
    const cut = (src.slice(0, begin - 4) + src.slice(end + "SHOP MODULE — END".length))
      .split("\n").filter(l => !/SHOP MODULE mount/.test(l)).join("\n")
      // The comment fence around the block outlives its contents.
      .replace(/\/\* =+\s*\n\s*=+ \*\//, "");
    const tmp = (process.env.TMPDIR || "/tmp") + "/paystamp-shopless.html";
    fs.writeFileSync(tmp, cut);

    const { browser, page, errors } = await open({
      appPath: tmp, role: "parent", rpc: { get_my_cards: PARENT_CARDS } });
    await page.waitForTimeout(700);
    await page.locator(".fam-kid-main").first().click();
    await page.waitForTimeout(500);
    const t = await text(page);
    ok("REMOVED: the app still boots with the module cut out", /Elena Georgiou/.test(t));
    ok("REMOVED: and there is no shop in it", !/Nothing for sale/i.test(t));
    ok("REMOVED: with no errors from what was left behind",
       errors.filter(e => !/Failed to load resource|ERR_/.test(e)).length === 0,
       errors.slice(0, 3).join(" | "));
    await browser.close();

    const { browser: b2, page: p2, errors: e2 } = await open({ appPath: tmp });
    await p2.waitForTimeout(600);
    await p2.locator(".dash-gear").first().click();
    await p2.waitForTimeout(400);
    const settings = await text(p2);
    ok("REMOVED: the owner's settings lose the Shop rows",
       !/Shop Orders/i.test(settings) && /Payment Link/i.test(settings), settings.slice(0, 400));
    ok("REMOVED: and the dashboard is otherwise intact",
       e2.filter(x => !/Failed to load resource|ERR_/.test(x)).length === 0, e2.slice(0, 3).join(" | "));
    await b2.close();
    fs.unlinkSync(tmp);

    const sql = fs.readFileSync(__dirname + "/../../supabase/migration-shop.sql", "utf8");
    ok("the migration alters no existing table",
       !/alter table (?!.*public\.shop_)/.test(sql));
    ok("and documents how to drop itself", /REMOVING THE MODULE/.test(sql));
    // The seam is granted to nobody. If that grant ever appears, any signed-in
    // parent could settle any order.
    ok("the payment seam is granted to nobody",
       !/grant execute on function public\.shop_order_mark_paid\(uuid,text,text\)/.test(sql));
  }

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
