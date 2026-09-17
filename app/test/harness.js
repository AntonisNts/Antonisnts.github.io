// Renders app/index.html against a mocked Supabase so screens can be driven
// and screenshotted. The app's own loaders run unchanged — only the client at
// `const sb = window.supabase.createClient(...)` is swapped, so the real
// row->view mapping (bizFromRow etc.) is what gets exercised.
const { chromium } = require("playwright");
const fs = require("fs");

const APP = "/home/user/Antonisnts.github.io/app/index.html";
const BIZ_ID = "biz-0001";

const pay = (o) => o;
const student = (i, name, level, groupId, payments) => ({
  id: "card-" + i, name, level, share_code: "SC" + (1000 + i), pin: "" + (1000 + i),
  phone: "+35799000" + (100 + i), payments: payments || {}, history: [],
  group_id: groupId || null, group_name: null, lesson_schedule: null,
  enrollment_start_month: null, paused_months: [], fee_history: [],
});

const FIXTURES = {
  businesses: [{
    id: BIZ_ID, biz_code: "STAMP01", name: "Aurora Music School", type: "Music",
    fee: 45, year: 2026, contact_email: "hello@aurora.example", inactive_months: [7],
    levels: [{ id: "lv1", name: "Beginner", fee: 40 }, { id: "lv2", name: "Advanced", fee: 60 }],
    accent: "violet", icon: null, custom_card: null,
  }],
  cards: [
    student(1, "Elena Georgiou", { id: "lv1", name: "Beginner" }, "grp1",
      pay({ "2026-01": { paid: true, amount: 40 }, "2026-02": { paid: true, amount: 40 }, "2026-03": { partial: true, amount: 20 } })),
    student(2, "Andreas Pavlou", { id: "lv2", name: "Advanced" }, "grp1", pay({ "2026-01": { paid: true, amount: 60 } })),
    student(3, "Maria Christodoulou", null, "grp2", pay({})),
    student(4, "Nikos Ioannou", { id: "lv1", name: "Beginner" }, null,
      pay({ "2026-01": { paid: true, amount: 40 }, "2026-02": { paid: true, amount: 40 } })),
  ],
  teachers: [{ id: "t1", name: "Sofia Markou" }, { id: "t2", name: "Petros Alexandrou" }],
  groups: [
    { id: "grp1", name: "Tuesday Piano", teacher_id: "t1", schedule: [{ day: "Tue", start_time: "16:00", end_time: "17:00" }] },
    { id: "grp2", name: "Thursday Violin", teacher_id: "t2", schedule: [{ day: "Thu", start_time: "18:00", end_time: "19:30" }] },
  ],
  registration_links: [
    { id: "rl1", group_id: "grp1", token: "abcd1234efgh", label: "September intake", is_active: true, created_at: "2026-08-01T10:00:00Z" },
    { id: "rl2", group_id: null, token: "zzzz9999yyyy", label: "Open enrolment", is_active: false, created_at: "2026-07-12T10:00:00Z" },
  ],
  registration_requests: [
    { id: "rq1", link_id: "rl1", group_id: "grp1", first_name: "Christos", last_name: "Demetriou", phone: "+35799123456", email: "c.dem@example.com", date_of_birth: "2014-04-02", status: "pending", card_id: null, created_at: "2026-08-28T09:00:00Z", decided_at: null },
    { id: "rq2", link_id: "rl1", group_id: "grp1", first_name: "Anna", last_name: "Solomou", phone: "+35799765432", email: "anna.s@example.com", date_of_birth: "2013-11-20", status: "pending", card_id: null, created_at: "2026-08-29T14:30:00Z", decided_at: null },
    { id: "rq3", link_id: "rl2", group_id: null, first_name: "Loukas", last_name: "Ttofi", phone: "+35799555111", email: null, date_of_birth: null, status: "approved", card_id: "card-4", created_at: "2026-08-02T08:00:00Z", decided_at: "2026-08-03T08:00:00Z" },
  ],
  announcements: [
    { id: "an1", business_id: BIZ_ID, title: "Summer recital", body: "The recital is on the 14th at 18:00 in the main hall.", is_pinned: true, created_at: "2026-08-20T09:00:00Z", audience: "all", group_id: null, level_id: null },
  ],
};

// A chainable stand-in for the postgrest builder: every filter/modifier returns
// itself, and awaiting it resolves with the table's fixture rows.
function installMock(fixtures, session, rpcExtra, rpcError) {
  const make = (table) => {
    const box = { rows: (fixtures[table] || []).slice() };
    const b = {};
    const chain = () => b;
    ["select", "eq", "neq", "in", "is", "not", "or", "gte", "lte", "gt", "lt",
      "like", "ilike", "order", "range", "match", "filter", "contains"].forEach((m) => { b[m] = chain; });
    b.limit = (n) => { box.rows = box.rows.slice(0, n); return b; };
    b.single = () => ({ then: (r) => r({ data: box.rows[0] || null, error: null }) });
    b.maybeSingle = b.single;
    ["insert", "update", "upsert", "delete"].forEach((m) => { b[m] = () => b; });
    b.then = (resolve) => resolve({ data: box.rows, error: null });
    return b;
  };
  const RPC = Object.assign({
    get_my_approval: "approved",
    get_my_cards: [],
    get_my_children: [],
    get_my_ann_reads: [],
    get_my_announcements: [],
    // Tap to Pay. A fixed token so the QR and the tag address render the same
    // way on every run; the real one is 24 random URL-safe characters.
    stamp_token_get: { ok: true, token: "TEST-TOKEN-0123456789ab",
                       created_at: "2026-09-01T00:00:00Z", require_pin: false, pin_set: false },
    // The stamp is off unless the school has calibrated one. Tests that want a
    // listening phone override these to { active: true }.
    stamp_trigger_active: { active: false },
    stamp_trigger_active_student: { active: false },
  }, rpcExtra || {});

  // A test that needs a call to answer differently the second time (spending a
  // single-use session, say) sets an array; each call shifts one off.
  const answer = (name) => {
    const v = RPC[name];
    if (Array.isArray(v) && v.__seq) return v.length > 1 ? v.shift() : v[0];
    return v !== undefined ? v : [];
  };
  // A database that has never had a migration run answers 404 for the
  // functions it has never heard of. Listing a name in `rpcError` reproduces
  // that, which is the state every already-deployed app is in the moment a new
  // module ships and before the owner runs its SQL.
  const broken = (rpcError || []).reduce((m, n) => (m[n] = true, m), {});
  const FAIL = { message: "Could not find the function in the schema cache", code: "PGRST202" };

  window.__MOCK_SB = {
    from: (t) => make(t),
    rpc: (name, args) => ({ then: (r) => { window.__RPC_CALLS = (window.__RPC_CALLS||[]).concat([[name, args||null]]); return r(broken[name] ? { data: null, error: FAIL } : { data: answer(name), error: null }); } }),
    channel: () => ({ on: function () { return this; }, subscribe: function () { return this; } }),
    removeChannel: () => {},
    storage: { from: () => ({ upload: async () => ({ data: null, error: null }), getPublicUrl: () => ({ data: { publicUrl: "" } }) }) },
    auth: {
      getSession: async () => ({ data: { session }, error: null }),
      getUser: async () => ({ data: { user: session.user }, error: null }),
      onAuthStateChange: (cb) => { setTimeout(() => cb("SIGNED_IN", session), 0); return { data: { subscription: { unsubscribe() {} } } }; },
      signOut: async () => ({ error: null }),
      signInWithPassword: async () => ({ data: { session }, error: null }),
    },
  };
}

async function open(opts) {
  opts = opts || {};
  // PLAYWRIGHT_CHROMIUM lets a machine that already has a browser point at it
  // rather than downloading a second copy, which is the usual situation when
  // the installed playwright and the preinstalled chromium are different
  // builds. Unset, playwright resolves its own as before.
  const exe = process.env.PLAYWRIGHT_CHROMIUM || "";
  const browser = await chromium.launch(exe ? { executablePath: exe } : {});
  const page = await browser.newPage({ viewport: opts.viewport || { width: 430, height: 932 } });
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  page.on("console", (m) => { if (m.type() === "error") errors.push("console: " + m.text()); });

  const session = opts.signedOut ? null
    : { user: { id: "u1", email: "owner@aurora.example", user_metadata: { role: opts.role || "teacher" } }, access_token: "tok" };
  await page.addInitScript(
    `(${installMock.toString()})(${JSON.stringify(opts.fixtures || FIXTURES)}, ${JSON.stringify(session)}, ${JSON.stringify(opts.rpc || {})}, ${JSON.stringify(opts.rpcError || [])});`
  );

  // Anything else that has to exist before the app's first line runs. Used to
  // stand in for browser APIs a headless run has no real version of --
  // Notification and PushManager, say, whose four states (grantable, granted,
  // denied, absent) are the whole behaviour of the notifications panel and
  // cannot otherwise be reached from a test.
  if (opts.init) await page.addInitScript(opts.init);

  // Swap only the client construction; every loader above it runs for real.
  const src = fs.readFileSync(opts.appPath || APP, "utf8")
    .replace("const sb = window.supabase.createClient(SB_URL, SB_KEY);", "const sb = window.__MOCK_SB;");
  await page.route(/app-under-test\.html/, (r) =>
    r.fulfill({ status: 200, contentType: "text/html", body: src }));

  // The app pulls React, Babel, Supabase and xlsx from unpkg/jsdelivr at run
  // time. On a normal machine those just load. Where egress is restricted,
  // drop the same files into app/test/vendor/ and they are served instead --
  // the app file itself is never modified, only the responses.
  const VENDOR = {
    "react@18/umd/react.production.min.js": "react.js",
    "react-dom@18/umd/react-dom.production.min.js": "react-dom.js",
    "@babel/standalone@7.23.5/babel.min.js": "babel.js",
    "xlsx@0.18.5/dist/xlsx.full.min.js": "xlsx.js",
    "@supabase/supabase-js@2/dist/umd/supabase.js": "supabase.js",
  };
  const vendorDir = __dirname + "/vendor/";
  if (fs.existsSync(vendorDir)) {
    await page.route(/unpkg\.com|cdn\.jsdelivr\.net/, (route) => {
      const url = route.request().url();
      const hit = Object.keys(VENDOR).find((k) => url.includes(k));
      const file = hit && vendorDir + VENDOR[hit];
      if (!file || !fs.existsSync(file)) return route.continue();
      route.fulfill({ status: 200, contentType: "application/javascript",
                      body: fs.readFileSync(file, "utf8") });
    });
  }

  await page.goto("https://paystamp.app/app-under-test.html" + (opts.query || ""), { waitUntil: "domcontentloaded" });

  await page.waitForSelector(".page, .dash-shell, .reg-page, .login-page, .landing, .hero", { timeout: 30000 });
  return { browser, page, errors };
}

module.exports = { open, FIXTURES, BIZ_ID };
