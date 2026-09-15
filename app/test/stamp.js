// The confirmation flow, driven in a real browser.
//
// sweep.js proves the owner's Tap to Pay screen opens. This drives the other
// side: what a parent actually sees after touching their phone to the tag.
// Each case boots the app at /app/?stamp=TOKEN with stamp_begin answering
// differently, because the four answers that function can give ARE the flow.
const { open } = require("./harness");

let pass = 0, fail = 0;
const ok = (n, c, d) => { c ? (pass++, console.log("  ok   " + n))
                            : (fail++, console.log("  FAIL " + n + (d ? " — " + d : ""))); };
const TOK = "?stamp=TEST-TOKEN-0123456789ab";

const SESSION = {
  ok: true, confirmation: "c0000000-0000-0000-0000-000000000001",
  expires_at: new Date(Date.now() + 60000).toISOString(),
  trigger: "nfc", require_pin: false, business_name: "Aurora Music School",
  type: "Music", accent: "violet", icon: null, year: 2026,
  students: [
    { card_id: "card-1", name: "Elena Georgiou", amount: 25, month: "March" },
    { card_id: "card-2", name: "Andreas Pavlou", amount: 60, month: "February" },
  ],
};

async function boot(rpc, opts) {
  return open(Object.assign({ query: TOK, role: "parent", rpc }, opts || {}));
}
const text = (page) => page.evaluate(() => document.body.innerText);

(async () => {
  // --- the tag resolves and a payment is recorded --------------------------
  {
    const { browser, page, errors } = await boot({
      stamp_begin: SESSION,
      stamp_confirm: { ok: true, n: 1, name: "Elena Georgiou", amount: 25, months: [2], trigger: "nfc" },
    });
    await page.waitForTimeout(700);
    let t = await text(page);
    ok("the school's name is shown", /Aurora Music School/i.test(t), t.slice(0, 90));
    ok("both children are offered", /Elena Georgiou/i.test(t) && /Andreas Pavlou/i.test(t));
    ok("the suggested month is shown", /Next unpaid month: March/i.test(t), t.slice(0, 160));

    const amt = await page.locator('input[type="number"]').inputValue();
    ok("the amount is prefilled from the server, not from zero", amt === "25", "got " + JSON.stringify(amt));

    ok("no PIN is asked for when the school has not required one",
       await page.locator('input[type="password"]').count() === 0);

    // Picking the other child must re-prefill; leaving the first child's
    // amount behind is the obvious bug here.
    await page.getByText("Andreas Pavlou", { exact: true }).first().click();
    await page.waitForTimeout(200);
    ok("switching child re-prefills that child's amount",
       (await page.locator('input[type="number"]').inputValue()) === "60");

    await page.getByText("Elena Georgiou", { exact: true }).first().click();
    await page.waitForTimeout(200);
    await page.getByText("Confirm Payment").first().click();
    await page.waitForTimeout(500);
    t = await text(page);
    ok("the payment is confirmed", /Payment recorded/i.test(t), t.slice(0, 120));
    ok("with the amount and the month it covered", /€25\.00/i.test(t) && /March/i.test(t));
    ok("and an undo is offered", await page.getByText("Undo", { exact: true }).count() > 0);

    const calls = await page.evaluate(() => window.__RPC_CALLS || []);
    const conf = calls.find(c => c[0] === "stamp_confirm");
    ok("confirm sends the session id, the card and the amount — and nothing else",
       conf && Object.keys(conf[1]).sort().join(",") === "p_amount,p_card_id,p_confirmation,p_pin",
       JSON.stringify(conf && conf[1]));
    ok("the card sent is the one selected", conf && conf[1].p_card_id === "card-1");

    // The token must not survive in the address bar, or a refresh re-fires it.
    const url = await page.evaluate(() => location.search);
    ok("the token is stripped from the URL", url === "", JSON.stringify(url));

    // accent arrives as a theme NAME. Published raw it is not a colour at all,
    // and the skin falls back to the :root default without anything failing.
    const pub = await page.evaluate(() =>
      (document.querySelector(".reg-page") || {style:{getPropertyValue:()=>""}})
        .style.getPropertyValue("--accent").trim());
    ok("the page publishes a real colour, not the theme's name",
       /^#|^rgb/.test(pub), JSON.stringify(pub));

    await browser.close();
    ok("no page errors", errors.filter(e => !/Failed to load resource|ERR_/.test(e)).length === 0,
       errors.slice(0, 3).join(" | "));
  }

  // --- undo ----------------------------------------------------------------
  {
    const { browser, page } = await boot({
      stamp_begin: SESSION,
      stamp_confirm: { ok: true, n: 1, name: "Elena Georgiou", amount: 25, months: [2] },
      stamp_undo: { ok: true },
    });
    await page.waitForTimeout(700);
    await page.getByText("Confirm Payment").first().click();
    await page.waitForTimeout(400);
    await page.getByText("Undo", { exact: true }).first().click();
    await page.waitForTimeout(400);
    const t = await text(page);
    ok("undo reports it was undone", /Undone/i.test(t) && /Nothing was kept/i.test(t), t.slice(0, 120));
    await browser.close();
  }

  // --- the PIN -------------------------------------------------------------
  {
    const { browser, page } = await boot({
      stamp_begin: Object.assign({}, SESSION, { require_pin: true }),
      stamp_confirm: { error: "bad_pin", burned: false },
    });
    await page.waitForTimeout(700);
    ok("a PIN field appears when the school requires one",
       await page.locator('input[type="password"]').count() === 1);

    await page.getByText("Confirm Payment").first().click();
    await page.waitForTimeout(300);
    ok("confirming with an empty PIN is stopped before the server is called",
       /Ask the school to enter their PIN/i.test(await text(page)));

    await page.locator('input[type="password"]').fill("9999");
    await page.getByText("Confirm Payment").first().click();
    await page.waitForTimeout(400);
    const t = await text(page);
    ok("a wrong PIN says so and stays on the form", /That PIN is not right/i.test(t) && /Confirm Payment/i.test(t), t.slice(0, 140));
    await browser.close();
  }

  // --- the owner's own device ----------------------------------------------
  {
    const { browser, page } = await boot({ stamp_begin: { owner: true, business_name: "Aurora Music School" } });
    await page.waitForTimeout(700);
    const t = await text(page);
    ok("the owner is told the tag works", /Your tag works/i.test(t), t.slice(0, 120));
    ok("and that nothing was recorded", /nothing has been recorded/i.test(t));
    const calls = await page.evaluate(() => window.__RPC_CALLS || []);
    ok("no confirmation is attempted for the owner", !calls.some(c => c[0] === "stamp_confirm"));
    await browser.close();
  }

  // --- somebody who is not a customer --------------------------------------
  {
    const { browser, page } = await boot({ stamp_begin: { error: "no_match" } });
    await page.waitForTimeout(700);
    const t = await text(page);
    ok("a stranger gets a generic message", /Nothing to confirm/i.test(t), t.slice(0, 120));
    ok("which names neither the school nor any student",
       !/Aurora/i.test(t) && !/Elena/i.test(t), t.slice(0, 160));
    await browser.close();
  }

  // --- an expired session ---------------------------------------------------
  {
    const { browser, page } = await boot({
      stamp_begin: Object.assign({}, SESSION, { expires_at: new Date(Date.now() - 1000).toISOString() }),
    });
    await page.waitForTimeout(900);
    ok("a session that has already run out asks them to tap again",
       /Please tap again/i.test(await text(page)));
    await browser.close();
  }

  // --- tapped while logged out ----------------------------------------------
  {
    const { browser, page } = await open({ query: TOK, signedOut: true, rpc: { stamp_begin: SESSION } });
    await page.waitForTimeout(700);
    const t = await text(page);
    ok("a logged-out tap lands on the family login", /Log in to confirm the payment/i.test(t), t.slice(0, 160));
    const held = await page.evaluate(() => sessionStorage.getItem("stamp_token"));
    ok("and the token is held so the login does not lose it",
       held === "TEST-TOKEN-0123456789ab", JSON.stringify(held));
    await browser.close();
  }

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
