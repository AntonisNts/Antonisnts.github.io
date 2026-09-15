const { open } = require("./harness");
const SETTINGS = ["Months","Levels","Groups","Manage","Colour","Icon","Card","Remind","Announcements","Registration","Tap to Pay","Export"];
let pass=0, fail=0;
const ok=(n,c,d)=>{ c?(pass++,console.log("  ok   "+n)):(fail++,console.log("  FAIL "+n+(d?" — "+d:""))); };
(async () => {
  const { browser, page, errors } = await open({});
  ok("dashboard renders", await page.locator(".dash-shell").count() > 0);

  for (const name of SETTINGS) {
    await page.locator(".dash-gear").first().click();
    await page.waitForTimeout(350);
    await page.locator(".set-ov").getByText(name, { exact: true }).locator("visible=true").first().click();
    await page.waitForTimeout(550);
    const st = await page.evaluate(() => {
      const r = document.querySelector(".page,.reg-page,.dash-shell");
      const title = (document.querySelector(".topbar h2")||{}).textContent || "";
      // A screen that consumes the accent must also publish it, or the class
      // silently falls back to the :root default.
      const consumers = document.querySelectorAll(".scr-lbl,.scr .ws-t,.scr-chip.on,.scr-btn.primary").length;
      const published = r ? (r.style.getPropertyValue("--accent") || "") : "";
      return { cls: r ? r.className : null, title, consumers, published };
    });
    ok(name+" opens on the skin", /\bscr\b/.test(st.cls||""), "root=" + st.cls);
    if (st.consumers > 0 && name !== "Icon")
      ok(name+" publishes --accent for its accent classes", !!st.published || st.cls.includes("fam"), "consumers=" + st.consumers + " published=" + JSON.stringify(st.published));
    await page.locator(".tb-back").first().click();
    await page.waitForTimeout(400);
  }

  // The card screen, reached from the student list.
  await page.locator("text=Elena Georgiou").locator("visible=true").first().click();
  await page.waitForTimeout(600);
  ok("student card on the skin", /\bscr\b/.test(await page.evaluate(()=>document.querySelector(".page").className)));

  const real = errors.filter(e=>!/ERR_CONNECTION_RESET|Failed to load resource/.test(e));
  ok("no page errors anywhere", real.length === 0, real.slice(0,4).join(" | "));
  console.log(`\n${pass} passed, ${fail} failed`);
  await browser.close();
  process.exit(fail?1:0);
})();
