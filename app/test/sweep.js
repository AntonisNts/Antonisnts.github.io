const { open } = require("./harness");
// Colour, Icon, Card and Name are behind "Customise" now -- four rows that
// were all the same question on a list that had grown to six groups.
const SETTINGS = ["Months","Levels","Groups","Manage","Customise","Remind","Announcements","Registration","Tap to Pay","Export"];
const CUSTOMISE = ["Name","Colour","Icon","Card"];
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

  // The four screens behind Customise still open, on the skin, as they did
  // when each had a settings row of its own.
  await page.locator(".dash-gear").first().click();
  await page.waitForTimeout(350);
  await page.locator(".set-ov").getByText("Customise", { exact: true }).locator("visible=true").first().click();
  await page.waitForTimeout(550);
  for (const name of CUSTOMISE) {
    await page.getByText(name, { exact: true }).locator("visible=true").first().click();
    await page.waitForTimeout(550);
    const st = await page.evaluate(() => {
      const r = document.querySelector(".page,.reg-page,.dash-shell");
      return { cls: r ? r.className : null,
               published: r ? (r.style.getPropertyValue("--accent") || "") : "" };
    });
    ok("Customise > " + name + " opens on the skin", /\bscr\b/.test(st.cls || ""), "root=" + st.cls);
    // Back from one of these lands on Customise, not the dashboard -- going
    // two levels in and one level out is how you lose people.
    await page.locator(".tb-back").first().click();
    await page.waitForTimeout(450);
    ok("and comes back to Customise",
       /Customise/.test(await page.evaluate(() => document.body.innerText)));
  }
  await page.locator(".tb-back").first().click();
  await page.waitForTimeout(450);

  // The QR actually drawn on the Tap to Pay screen. The matrix itself is
  // covered in qr.js; what this adds is that it reaches the canvas at all --
  // the first version of this screen showed the "could not load" fallback on a
  // real phone and looked perfectly fine in every other test.
  await page.locator(".dash-gear").first().click();
  await page.waitForTimeout(350);
  await page.locator(".set-ov").getByText("Tap to Pay", { exact: true }).locator("visible=true").first().click();
  await page.waitForTimeout(700);
  const qr = await page.evaluate(() => {
    const cv = document.querySelector("canvas");
    if (!cv || !cv.width) return { drawn: false, reason: "no canvas" };
    const g = cv.getContext("2d");
    const d = g.getImageData(0, 0, cv.width, cv.height).data;
    let dark = 0;
    for (let i = 0; i < d.length; i += 4) if (d[i] < 128) dark++;
    return { drawn: true, w: cv.width, dark, total: d.length / 4,
             fallback: /could not be drawn/i.test(document.body.innerText) };
  });
  ok("the QR canvas is drawn", qr.drawn, qr.reason);
  ok("no fallback message is shown", qr.drawn && !qr.fallback);
  // A blank or all-black canvas would still "draw". Real QRs land near 40-50%.
  ok("the canvas holds a plausible QR, not a blank square",
     qr.drawn && qr.dark / qr.total > 0.2 && qr.dark / qr.total < 0.7,
     qr.drawn ? Math.round(qr.dark / qr.total * 100) + "% dark" : "");
  await page.locator(".tb-back").first().click();
  await page.waitForTimeout(400);

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
