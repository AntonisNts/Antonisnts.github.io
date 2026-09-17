// Push notifications, in a real browser.
//
// The complaint this answers, in the owner's words: "when the business sends a
// message the users get notified [on Viber] but when they send in the app it's
// just a website that the users have to open frequently and check it."
//
// What cannot be tested here: that a real push service delivers a real push.
// That needs the Edge Function deployed and a real device, and no harness
// substitutes for it. What CAN be tested is everything on this side of that
// line, and it is where the mistakes are:
//
//   - the four states a device can be in, and that each is told the truth
//   - an iPhone in a Safari tab gets an instruction, not a dead button
//   - the browser is only asked for permission after a deliberate press
//   - a subscription we failed to record is undone, not left looking "on"
//   - the service worker shows what it was sent, and does not cache the app
const { open, FIXTURES } = require("./harness");
const fs = require("fs");

let pass = 0, fail = 0;
const ok = (n, c, d) => { c ? (pass++, console.log("  ok   " + n))
                            : (fail++, console.log("  FAIL " + n + (d ? " — " + d : ""))); };
const text = (page) => page.evaluate(() => document.body.innerText);

const CARDS = [{
  card: { id: "card-1", name: "Elena Georgiou", level: null, share_code: "SC1",
          payments: {}, history: [] },
  business: { name: "Aurora Music School", type: "Music", fee: 45, year: 2026,
              biz_code: "STAMP01", inactive_months: [], levels: [], custom_card_image: null },
}];

/* A stand-in for the browser's push machinery.
   `perm` is what Notification.permission reports; `grant` what the prompt
   returns; `has` whether a subscription already exists. Headless Chromium has
   real versions of some of this, but not one a test can put into "denied" or
   take away entirely, which is most of what matters. */
const stub = (o) => `(() => {
  const S = ${JSON.stringify(o)};
  window.__PUSH = { asked: 0, subscribed: 0, unsubscribed: 0, registered: [] };
  const SUB = {
    endpoint: "https://push.example.com/ep/abc123",
    toJSON: () => ({ endpoint: "https://push.example.com/ep/abc123",
                     keys: { p256dh: "BPubKeyHere", auth: "AuthSecret" } }),
    unsubscribe: async () => { window.__PUSH.unsubscribed++; return true; },
  };
  let current = S.has ? SUB : null;
  if (S.noPush) {
    try { delete window.PushManager; } catch (e) {}
    Object.defineProperty(window, "PushManager", { value: undefined, configurable: true });
  } else {
    window.PushManager = function () {};
  }
  if (S.noNotification) {
    Object.defineProperty(window, "Notification", { value: undefined, configurable: true });
  } else {
    window.Notification = {
      permission: S.perm || "default",
      requestPermission: async () => {
        window.__PUSH.asked++;
        window.Notification.permission = S.grant || "granted";
        return window.Notification.permission;
      },
    };
  }
  const reg = {
    pushManager: {
      getSubscription: async () => current,
      subscribe: async (opts) => {
        window.__PUSH.subscribed++;
        window.__PUSH.appKey = opts && opts.applicationServerKey
          ? Array.from(opts.applicationServerKey).length : 0;
        window.__PUSH.userVisibleOnly = !!(opts && opts.userVisibleOnly);
        current = SUB; return SUB;
      },
    },
  };
  Object.defineProperty(navigator, "serviceWorker", {
    configurable: true,
    value: {
      register: async (u, o) => { window.__PUSH.registered.push([u, o && o.scope]); return reg; },
      getRegistration: async () => (S.hasReg === false ? null : reg),
      ready: Promise.resolve(reg),
    },
  });
  window.__BADGE = [];
  navigator.setAppBadge = async (n) => { window.__BADGE.push(n); };
  navigator.clearAppBadge = async () => { window.__BADGE.push(0); };
  if (S.ua) Object.defineProperty(navigator, "userAgent", { value: S.ua, configurable: true });
})()`;

// `reads` is announcement_reads rows, not an RPC: the app selects them from
// the table directly, so overriding a function name would have done nothing.
const openPortal = (o, rpc, reads) => open({
  role: "parent", init: stub(o),
  fixtures: Object.assign({}, FIXTURES, { announcement_reads: reads || [] }),
  rpc: Object.assign({ get_my_cards: CARDS, push_status: { on: false } }, rpc || {}) });

(async () => {
  // === a device that can be switched on =====================================
  {
    const { browser, page, errors } = await openPortal({}, { push_subscribe: { ok: true } });
    await page.waitForTimeout(900);

    let t = await text(page);
    ok("the portal offers notifications", /Get told about announcements/i.test(t), t.slice(0, 200));
    ok("and says what they are for, and what they are not",
       /Instead of opening PayStamp to check/i.test(t) &&
       /nothing else/i.test(t));

    // A prompt that appears unasked is the one people dismiss forever, and
    // "denied" cannot be undone by us.
    ok("the browser has NOT been asked yet",
       (await page.evaluate(() => window.__PUSH.asked)) === 0);
    ok("and no service worker has been installed yet",
       (await page.evaluate(() => window.__PUSH.registered.length)) === 0);

    await page.locator('button:has-text("Turn On Notifications")').first().click();
    await page.waitForTimeout(600);

    const st = await page.evaluate(() => window.__PUSH);
    ok("pressing it asks once", st.asked === 1, JSON.stringify(st));
    ok("registers the worker at the app's own scope",
       st.registered.length === 1 && st.registered[0][0] === "/app/sw.js"
       && st.registered[0][1] === "/app/", JSON.stringify(st.registered));
    ok("and subscribes", st.subscribed === 1);
    // userVisibleOnly is not optional: without it Chrome refuses, and a silent
    // push is not what anybody agreed to anyway.
    ok("promising every push will be visible", st.userVisibleOnly === true);
    // 65 bytes is an uncompressed P-256 point. A mangled key subscribes fine
    // and then never delivers, which is the worst way for this to fail.
    ok("with a VAPID key of the right shape", st.appKey === 65, "len " + st.appKey);

    const sent = await page.evaluate(() => (window.__RPC_CALLS || [])
      .find(c => c[0] === "push_subscribe"));
    ok("the subscription is handed to the database whole",
       sent && sent[1].p_endpoint === "https://push.example.com/ep/abc123"
       && sent[1].p_p256dh === "BPubKeyHere" && sent[1].p_auth === "AuthSecret",
       JSON.stringify(sent && sent[1]));

    t = await text(page);
    // Not "the panel vanishes": the only feedback for pressing a button must
    // not be the button disappearing.
    ok("and it confirms, then and there", /Notifications are on/i.test(t), t.slice(0, 200));
    ok("stopping the invitation", !/Get told about announcements/i.test(t));

    await browser.close();
    ok("no page errors", errors.filter(e => !/Failed to load resource|ERR_/.test(e)).length === 0,
       errors.slice(0, 3).join(" | "));
  }

  // === the iPhone problem ===================================================
  // On iOS there is no PushManager in a Safari tab at all — not a refused
  // permission, no API. A button would be a dead end; an instruction is not.
  {
    const { browser, page } = await openPortal({
      noPush: true, noNotification: true,
      ua: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 Safari/604.1" });
    await page.waitForTimeout(900);
    const t = await text(page);
    ok("an iPhone in a tab is told to install, not offered a dead button",
       /Add to Home Screen/i.test(t), t.slice(0, 300));
    ok("with the actual steps", /Share/i.test(t) && /Safari/i.test(t));
    ok("and no button that cannot work",
       await page.getByRole("button", { name: /Turn On Notifications/i }).count() === 0);
    await browser.close();
  }

  // A browser with genuinely no push says nothing on the front page — there is
  // no instruction to give, and explaining a limitation nobody can act on is
  // just noise on a screen whose whole point is being quiet.
  {
    const { browser, page } = await openPortal({
      noPush: true, noNotification: true,
      ua: "Mozilla/5.0 (Windows NT 10.0) AppleWebKit/537.36 Chrome/50 Safari/537.36" });
    await page.waitForTimeout(900);
    const t = await text(page);
    ok("a browser with no push at all is not lectured about it",
       !/Get told about announcements/i.test(t) && !/Add to Home Screen/i.test(t),
       t.slice(0, 250));
    ok("and the portal is otherwise itself", /Elena Georgiou/.test(t));
    await browser.close();
  }

  // === already refused ======================================================
  {
    const { browser, page } = await openPortal({ perm: "denied" });
    await page.waitForTimeout(900);
    const t = await text(page);
    ok("a device that already refused is not nagged on the front page",
       !/Turn On Notifications/i.test(t), t.slice(0, 250));

    await page.locator('.tb-act').first().click();
    await page.waitForTimeout(500);
    const acc = await text(page);
    ok("but Account explains it, because that is where you go to look",
       /Notifications are blocked/i.test(acc), acc.slice(0, 300));
    ok("and says honestly that only they can undo it",
       /Only you can change that/i.test(acc));
    ok("the browser was never asked again",
       (await page.evaluate(() => window.__PUSH.asked)) === 0);
    await browser.close();
  }

  // === pressed, then refused ================================================
  {
    const { browser, page } = await openPortal({ grant: "denied" });
    await page.waitForTimeout(900);
    await page.locator('button:has-text("Turn On Notifications")').first().click();
    await page.waitForTimeout(500);
    const st = await page.evaluate(() => window.__PUSH);
    ok("refusing the prompt subscribes nothing", st.subscribed === 0, JSON.stringify(st));
    const sent = await page.evaluate(() => (window.__RPC_CALLS || [])
      .filter(c => c[0] === "push_subscribe").length);
    ok("and tells the database nothing", sent === 0);
    await browser.close();
  }

  // === the database refuses to record it ====================================
  // The failure that would be invisible: the browser is subscribed, the panel
  // says "on", and nothing is ever sent to it because we never stored it.
  {
    const { browser, page } = await openPortal({}, { push_subscribe: { error: "bad_endpoint" } });
    await page.waitForTimeout(900);
    await page.locator('button:has-text("Turn On Notifications")').first().click();
    await page.waitForTimeout(700);
    const st = await page.evaluate(() => window.__PUSH);
    ok("a subscription we could not record is UNDONE, not left looking on",
       st.subscribed === 1 && st.unsubscribed === 1, JSON.stringify(st));
    const t = await text(page);
    ok("and the parent is told it did not work",
       /could not be switched on/i.test(t), t.slice(0, 250));
    ok("rather than being told it did", !/Notifications are on/i.test(t));
    await browser.close();
  }

  // === already on, and turning it off =======================================
  {
    const { browser, page } = await openPortal({ perm: "granted", has: true },
      { push_status: { on: true }, push_unsubscribe: { ok: true } });
    await page.waitForTimeout(900);
    const t0 = await text(page);
    ok("a device already subscribed is not asked again", !/Turn On Notifications/i.test(t0));
    // Next time round it is gone entirely -- it has nothing left to say.
    ok("and takes up no room on the front page at all",
       !/Notifications are on/i.test(t0) && !/Get told about/i.test(t0), t0.slice(0, 250));

    await page.locator('.tb-act').first().click();
    await page.waitForTimeout(500);
    ok("Account says they are on", /Notifications are on/i.test(await text(page)));

    await page.locator('button:has-text("Turn Off")').first().click();
    await page.waitForTimeout(600);
    const sent = await page.evaluate(() => (window.__RPC_CALLS || [])
      .find(c => c[0] === "push_unsubscribe"));
    ok("turning off tells the database which browser stopped",
       sent && sent[1].p_endpoint === "https://push.example.com/ep/abc123",
       JSON.stringify(sent && sent[1]));
    ok("and the browser unsubscribes too, not just our record",
       (await page.evaluate(() => window.__PUSH.unsubscribed)) === 1);
    await browser.close();
  }

  // A browser holding a subscription we have no record of is NOT on: nothing
  // would ever be sent to it. Cleared site data and restored backups do this.
  {
    const { browser, page } = await openPortal({ perm: "granted", has: true },
      { push_status: { on: false } });
    await page.waitForTimeout(900);
    ok("a subscription the database never stored is offered again, not called on",
       /Turn On Notifications/i.test(await text(page)));
    await browser.close();
  }

  // === the service worker ===================================================
  // Loaded into a page with a stand-in `self`, the way qr.js lifts qrMatrix
  // out of index.html — so what is checked is the file that ships.
  {
    const { browser, page } = await open({ role: "parent", rpc: { get_my_cards: CARDS } });
    const SW = fs.readFileSync(__dirname + "/../sw.js", "utf8");

    const r = await page.evaluate(([src]) => {
      const handlers = {};
      const shown = [];
      const opened = [];
      const self = {
        addEventListener: (k, fn) => { handlers[k] = fn; },
        skipWaiting: () => {},
        clients: {
          claim: () => {},
          matchAll: async () => [],
          openWindow: async (u) => { opened.push(u); return {}; },
        },
        registration: {
          showNotification: (title, opts) => { shown.push({ title, opts }); },
        },
      };
      // eslint-disable-next-line no-new-func
      new Function("self", src)(self);

      const waits = [];
      const ev = (data) => ({ data, waitUntil: (p) => waits.push(p) });

      handlers.push(ev({ json: () => ({
        title: "Aurora Music School", body: "Recital on the 14th",
        url: "/app/", tag: "ann-1" }) }));
      // A push with a body that is not JSON must still show something: a
      // browser requires a notification for every push it delivers.
      handlers.push(ev({ json: () => { throw new Error("not json"); } }));
      // And one with no payload at all.
      handlers.push({ waitUntil: (p) => waits.push(p) });

      return { hasFetch: !!handlers.fetch, keys: Object.keys(handlers), shown };
    }, [SW]);

    // The single most important assertion in this file. PayStamp is one HTML
    // file deployed by overwriting it; a service worker that cached it would
    // serve last week's app to a school with no way for them to tell.
    ok("THE SERVICE WORKER DOES NOT INTERCEPT FETCHES", r.hasFetch === false,
       "handlers: " + r.keys.join(","));
    ok("it handles push and clicks and nothing else",
       r.keys.sort().join(",") === "activate,install,notificationclick,push", r.keys.join(","));

    ok("a push shows the school as the title and the headline as the body",
       r.shown[0] && r.shown[0].title === "Aurora Music School"
       && r.shown[0].opts.body === "Recital on the 14th",
       JSON.stringify(r.shown[0]));
    ok("tagged per announcement, so two schools do not overwrite each other",
       r.shown[0].opts.tag === "ann-1");
    ok("a push whose payload is not JSON still shows something",
       r.shown[1] && r.shown[1].title === "PayStamp", JSON.stringify(r.shown[1]));
    ok("and so does one with no payload at all",
       r.shown[2] && r.shown[2].title === "PayStamp", JSON.stringify(r.shown[2]));
    ok("every notification carries an icon, or the OS picks its own",
       r.shown.every(x => !!x.opts.icon));

    // Clicking it should reuse an open PayStamp rather than opening a second.
    const click = await page.evaluate(([src]) => {
      const handlers = {};
      const focused = [], opened = [], navigated = [];
      const self = {
        addEventListener: (k, fn) => { handlers[k] = fn; },
        skipWaiting: () => {}, registration: { showNotification: () => {} },
        clients: {
          claim: () => {},
          matchAll: async () => ([{ url: "https://paystamp.app/app/",
            focus: () => { focused.push(1); return {}; },
            navigate: async (u) => { navigated.push(u); } }]),
          openWindow: async (u) => { opened.push(u); return {}; },
        },
      };
      new Function("self", src)(self);
      const waits = [];
      handlers.notificationclick({
        notification: { close: () => {}, data: { url: "/app/" } },
        waitUntil: (p) => waits.push(p),
      });
      return Promise.all(waits).then(() => ({ focused: focused.length, opened, navigated }));
    }, [SW]);
    ok("clicking focuses PayStamp if it is already open", click.focused === 1,
       JSON.stringify(click));
    ok("rather than opening a second copy", click.opened.length === 0);

    await browser.close();
  }

  // === the student portal ===================================================
  // A family with one child at one school never makes an account, and
  // push_subscribe reads auth.email() -- so the switch could not work for them.
  {
    const STU = {
      card: { id: "card-1", name: "Andriana", level: null, share_code: "AQ3RG0",
              payments: {}, history: [] },
      business: { name: "Dance School", type: "Other", fee: 50, year: 2026, biz_code: "B1",
                  inactive_months: [], levels: [], custom_card_image: null },
      announcements: [],
    };
    const { browser, page, errors } = await open({
      signedOut: true, init: stub({}),
      rpc: { get_student_card: STU, push_status_student: { on: false },
             push_subscribe_student: { ok: true } } });
    await page.waitForTimeout(700);
    await page.getByText("Quick View").click();
    await page.waitForTimeout(500);
    await page.locator("input.inp").first().fill("AQ3RG0");
    await page.locator("button.btn").first().click();
    await page.waitForTimeout(500);
    await page.locator("input.inp").first().fill("1234");
    await page.locator("button.btn").first().click();
    await page.waitForTimeout(900);

    let t = await text(page);
    ok("the student portal offers notifications too",
       /Get told about announcements/i.test(t), t.slice(0, 300));
    // A student is not being told about "your children's schools".
    ok("worded for a student, not a parent",
       /from your school/i.test(t) && !/children's schools/i.test(t), t.slice(0, 400));
    ok("and the browser has not been asked yet",
       (await page.evaluate(() => window.__PUSH.asked)) === 0);

    await page.locator('button:has-text("Turn On Notifications")').first().click();
    await page.waitForTimeout(700);

    const sent = await page.evaluate(() => (window.__RPC_CALLS || [])
      .find(c => c[0] === "push_subscribe_student"));
    ok("subscribing proves who they are with the code and PIN",
       sent && sent[1].p_code === "AQ3RG0" && sent[1].p_pin === "1234",
       JSON.stringify(sent && sent[1]));
    ok("and hands over the same three things a parent's does",
       sent && sent[1].p_endpoint === "https://push.example.com/ep/abc123"
       && sent[1].p_p256dh === "BPubKeyHere" && sent[1].p_auth === "AuthSecret",
       JSON.stringify(sent && sent[1]));
    // The parent's function reads auth.email(), which is null here: it would
    // not leak, it would silently do nothing.
    ok("never through the signed-in parent's function",
       !(await page.evaluate(() => (window.__RPC_CALLS || [])
         .some(c => c[0] === "push_subscribe"))));
    ok("and it confirms", /Notifications are on/i.test(await text(page)));

    await browser.close();
    ok("no page errors in the student portal",
       errors.filter(e => !/Failed to load resource|ERR_/.test(e)).length === 0,
       errors.slice(0, 3).join(" | "));
  }

  // An iPhone in a Safari tab gets the same instruction here as in the family
  // portal -- there is no push machinery to offer a button for.
  {
    const { browser, page } = await open({
      signedOut: true,
      init: stub({ noPush: true, noNotification: true,
        ua: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 Safari/604.1" }),
      rpc: { get_student_card: {
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
    const t = await text(page);
    ok("an iPhone student is told to install, not offered a dead button",
       /Add to Home Screen/i.test(t) &&
       await page.getByRole("button", { name: /Turn On Notifications/i }).count() === 0,
       t.slice(0, 300));
    await browser.close();
  }

  // === the number on the app icon ===========================================
  // "why doesn't it show 1 as a notification on the home page icon like
  //  StoryReel has 197?" -- because a banner and a badge are two different
  //  things, and only the first was being set.
  {
    const NOTE = (n) => Array.from({ length: n }, (_, i) => ({
      id: "a" + i, business_name: "Aurora Music School", title: "Note " + i,
      body: "x", created_at: "2026-09-1" + i + "T09:00:00Z", target_kind: "all" }));

    const { browser, page } = await openPortal({}, { get_my_announcements: NOTE(3) },
      [{ announcement_id: "a0" }]);
    await page.waitForTimeout(900);
    const b = await page.evaluate(() => window.__BADGE);
    // Two unread of three. The badge must equal what the portal shows, not how
    // many pushes were sent -- a badge that disagrees is worse than none.
    ok("the icon carries the unread count", b[b.length - 1] === 2, JSON.stringify(b));
    await browser.close();
  }

  {
    const { browser, page } = await openPortal({}, {
      get_my_announcements: [{ id: "a1", business_name: "Aurora Music School",
        title: "Read", body: "x", created_at: "2026-09-10T09:00:00Z", target_kind: "all" }] },
      [{ announcement_id: "a1" }]);
    await page.waitForTimeout(900);
    const b = await page.evaluate(() => window.__BADGE);
    ok("and is cleared when there is nothing unread", b[b.length - 1] === 0, JSON.stringify(b));
    await browser.close();
  }

  // The worker sets it too, from the count the sender worked out -- counting in
  // the worker would drift the moment they read something on another device.
  {
    const { browser, page } = await open({ role: "parent", rpc: { get_my_cards: CARDS } });
    const SW = fs.readFileSync(__dirname + "/../sw.js", "utf8");
    const r = await page.evaluate(([src]) => {
      const handlers = {}, badges = [];
      const self = {
        addEventListener: (k, fn) => { handlers[k] = fn; },
        skipWaiting: () => {}, clients: { claim: () => {} },
        navigator: { setAppBadge: (n) => badges.push(n),
                     clearAppBadge: () => badges.push(0) },
        registration: { showNotification: () => {} },
      };
      new Function("self", src)(self);
      const ev = (d) => ({ data: { json: () => d }, waitUntil: () => {} });
      handlers.push(ev({ title: "S", body: "b", badge: 4 }));
      handlers.push(ev({ title: "S", body: "b", badge: 0 }));
      handlers.push(ev({ title: "S", body: "b" }));     // no badge in the payload
      return badges;
    }, [SW]);
    ok("a push sets the badge to what the sender counted", r[0] === 4, JSON.stringify(r));
    ok("and clears it when that count is zero", r[1] === 0, JSON.stringify(r));
    // An older sender, or a payload without one, must not blank a correct badge.
    // This is the student case, not a hypothetical: the student portal records
    // what has been read in localStorage, so the sender has no count to give
    // and sends none rather than a wrong one.
    ok("a payload with no count leaves the badge alone", r.length === 2, JSON.stringify(r));
    await browser.close();
  }

  // === the sending half, as far as it can be checked here ===================
  // The Edge Function cannot run in this harness. What can be checked is that
  // it has not been written with the private key or the authentication check
  // missing, which are the two ways it would be dangerous rather than broken.
  {
    const fn = fs.readFileSync(
      __dirname + "/../../supabase/functions/push-announcement/index.ts", "utf8");
    ok("the sender authenticates its caller",
       /PUSH_HOOK_SECRET/.test(fn) && /401/.test(fn));
    ok("in constant time, so the secret cannot be guessed a character at a time",
       /sameSecret/.test(fn) && /\^/.test(fn));
    ok("it reads the audience from the database rather than re-deriving it",
       /push_audience/.test(fn));
    ok("and prunes endpoints the push service says are gone",
       /410/.test(fn) && /push_mark_gone/.test(fn));
    // The badge is per person, so the payload cannot be built once and reused.
    ok("the badge is built per subscription, not once for everybody",
       /bodyFor\(s\.badge\)/.test(fn), "");
    // A key pasted into a file is a key in git history forever.
    ok("NO PRIVATE KEY IS IN THE REPOSITORY",
       /Deno\.env\.get\("VAPID_PRIVATE_KEY"\)/.test(fn) &&
       !/BEGIN [A-Z ]*PRIVATE KEY/.test(fn));

    const app = fs.readFileSync(__dirname + "/../index.html", "utf8");
    const pub = (app.match(/VAPID_PUBLIC_KEY\s*=\s*\n?\s*"([^"]+)"/) || [])[1];
    ok("the app ships a VAPID public key", !!pub);
    // 65 raw bytes -> 87 base64url characters. A truncated key subscribes
    // happily and then never delivers anything.
    ok("of the right length for an uncompressed P-256 point",
       pub && pub.length === 87 && pub[0] === "B", pub && (pub.length + " chars"));

    const sql = fs.readFileSync(__dirname + "/../../supabase/migration-push.sql", "utf8");
    // An endpoint is a capability to make somebody's phone buzz.
    ok("no ordinary user can read who is subscribed",
       /revoke all on function public\.push_audience\(uuid\)\s+from public, anon, authenticated/.test(sql));
    ok("only the service role can", /grant execute on function public\.push_audience\(uuid\)\s+to service_role/.test(sql));
    ok("and the table itself is reachable by nobody",
       /revoke all on table public\.push_subscriptions from public, anon, authenticated/.test(sql));
  }

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
