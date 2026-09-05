/**
 * Headless play-through, for checking the round still works after a change.
 *
 *   npm run build && npm run preview     # in one shell
 *   node tools/playtest.mjs              # in another
 *
 * It drives real pointer drags against the built game, aims each shot at the
 * third holding the correct answer, and reports what the round did. Anything
 * printed under ERRORS came from the page itself.
 */
import { chromium } from 'playwright';

const url = process.env.URL ?? 'http://localhost:4173/?debug=1';
const browser = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
const page = await browser.newPage({ viewport: { width: 1280, height: 800 }, deviceScaleFactor: 1 });

const errors = [];
page.on('console', (message) => {
  if (message.type() === 'error') errors.push(message.text());
});
page.on('pageerror', (error) => errors.push(`pageerror: ${error.message}`));

await page.goto(url, { waitUntil: 'networkidle' });
await page.waitForTimeout(900);

const read = () => page.evaluate(() => window.penaltySums.inspect());

// Pull back along the opposite diagonal: the gesture is a catapult, so a drag
// down and to the right sends the ball up and to the left.
const aimAt = { 0: [121, 110], 1: [0, 120], 2: [-121, 110] };

const log = [];
for (let shot = 0; shot < 24; shot++) {
  const before = await read();
  if (before.phase === 'ended') break;
  const [dx, dy] = aimAt[before.answerThird];
  const x = 640;
  const y = 520;
  await page.mouse.move(x, y);
  await page.mouse.down();
  for (let step = 1; step <= 10; step++) {
    await page.mouse.move(x + (dx * step) / 10, y + (dy * step) / 10);
    await page.waitForTimeout(14);
  }
  await page.mouse.up();
  await page.waitForTimeout(3600);
  const after = await read();
  log.push(
    `shot ${shot + 1}: aimed at third ${before.answerThird} -> penalty ${after.penalty}, ` +
      `${after.goals} goals, ${after.saves} saves, ${after.correct} correct`,
  );
  if (after.phase === 'ended') break;
}

console.log(log.join('\n'));
console.log('final', JSON.stringify(await read()));
console.log(errors.length ? `ERRORS:\n${errors.slice(0, 8).join('\n')}` : 'no console errors');
await browser.close();
