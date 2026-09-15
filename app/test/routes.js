// The two static doorways -- /stamp/ and 404.html -- served the way GitHub
// Pages serves them: a real file if one exists at that path, 404.html if not.
//
// Worth a test of its own because the nicer tag address, /stamp/TOKEN, is not
// a file. It only works because the site's 404 page rewrites it, and that is
// exactly the kind of arrangement that breaks quietly.
const { chromium } = require("playwright");
const fs = require("fs");
const R = __dirname + "/../../";
let pass=0, fail=0;
const ok=(n,c,d)=>{c?(pass++,console.log("  ok   "+n)):(fail++,console.log("  FAIL "+n+(d?" — "+d:"")));};
(async () => {
  const exe = process.env.PLAYWRIGHT_CHROMIUM || "";
  const b = await chromium.launch(exe ? { executablePath: exe } : {});
  const p = await b.newPage();
  await p.route(/paystamp\.test/, (route) => {
    const u = new URL(route.request().url());
    let f = null;
    if (u.pathname === "/stamp/" || u.pathname === "/stamp") f = R + "stamp/index.html";
    else if (u.pathname === "/app/") f = R + "app/index.html";
    else if (fs.existsSync(R + u.pathname.replace(/^\//, "")) &&
             fs.statSync(R + u.pathname.replace(/^\//, "")).isFile()) f = R + u.pathname.replace(/^\//, "");
    if (!f) f = R + "404.html";                      // what Pages does
    route.fulfill({ status: 200, contentType: "text/html", body: fs.readFileSync(f, "utf8") });
  });

  await p.goto("https://paystamp.test/stamp/?t=ABC123", { waitUntil: "domcontentloaded" });
  await p.waitForTimeout(400);
  ok("/stamp/?t=TOKEN forwards into the app",
     /\/app\/\?stamp=ABC123/.test(p.url()), p.url());

  await p.goto("https://paystamp.test/stamp/PATHTOKEN", { waitUntil: "domcontentloaded" });
  await p.waitForTimeout(600);
  ok("/stamp/TOKEN goes through 404.html and lands in the app",
     /\/app\/\?stamp=PATHTOKEN/.test(p.url()), p.url());

  await p.goto("https://paystamp.test/stamp/TOK?n=abc123", { waitUntil: "domcontentloaded" });
  await p.waitForTimeout(600);
  ok("the QR nonce survives both hops",
     /stamp=TOK/.test(p.url()) && /n=abc123/.test(p.url()), p.url());

  await p.goto("https://paystamp.test/stamp/", { waitUntil: "domcontentloaded" });
  await p.waitForTimeout(400);
  ok("a tag with no code says so instead of redirecting",
     /Nothing to confirm/i.test(await p.evaluate(()=>document.body.innerText)) && !/\/app\//.test(p.url()), p.url());

  await p.goto("https://paystamp.test/no/such/page", { waitUntil: "domcontentloaded" });
  await p.waitForTimeout(400);
  const t = await p.evaluate(()=>document.body.innerText);
  ok("an ordinary wrong address still gets a plain 404, not the app",
     /Page not found/i.test(t) && !/\/app\//.test(p.url()), p.url()+" "+t.slice(0,60));

  await b.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail?1:0);
})();
