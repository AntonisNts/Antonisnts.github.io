/**
 * The maths layer.
 *
 * Questions are generated, never drawn from a fixed list, and they are always
 * framed as a job on the pitch or in the shop rather than as a bare sum.
 *
 * Wrong answers are made by applying a realistic error — an off-by-ten, the
 * operation reversed, two digits swapped, a neighbouring times-table row. A
 * random far-off number would make the right answer obvious and the game
 * would stop teaching.
 */

export type Tier = 1 | 2 | 3;

export type Question = {
  tier: Tier;
  prompt: string;
  answer: number;
  /** The three numbers to show, already shuffled. */
  choices: [number, number, number];
};

const randInt = (min: number, max: number) => min + Math.floor(Math.random() * (max - min + 1));
const pick = <T>(items: readonly T[]): T => items[randInt(0, items.length - 1)] as T;

/** Countable things a child would meet on a pitch or in a shop. */
const crates = [
  { one: 'το καφάσι', many: 'πορτοκάλια', holder: 'καφάσι' },
  { one: 'το κιβώτιο', many: 'μήλα', holder: 'κιβώτιο' },
  { one: 'ο σάκος', many: 'μπάλες', holder: 'σάκο' },
  { one: 'το ράφι', many: 'κούπες', holder: 'ράφι' },
] as const;

const groups = [
  { unit: 'δίχτυ', units: 'δίχτυα', item: 'μπάλες' },
  { unit: 'κουτί', units: 'κουτιά', item: 'αυτοκόλλητα' },
  { unit: 'παγκάκι', units: 'παγκάκια', item: 'παίκτες' },
  { unit: 'τσάντα', units: 'τσάντες', item: 'κάλτσες' },
] as const;

// ---------------------------------------------------------------------------
// plausible wrong answers
// ---------------------------------------------------------------------------

function swapDigits(n: number): number | null {
  const s = String(n);
  if (s.length < 2) return null;
  const swapped = Number(s[1]! + s[0]! + s.slice(2));
  return swapped === n ? null : swapped;
}

/**
 * Build two wrong answers around the right one. Each candidate is a mistake a
 * child actually makes; the first two that are positive, distinct and not the
 * answer itself are the ones shown.
 */
function distractors(answer: number, candidates: readonly (number | null)[]): [number, number] {
  const chosen: number[] = [];
  for (const candidate of candidates) {
    if (candidate === null) continue;
    if (!Number.isFinite(candidate)) continue;
    if (candidate <= 0 || candidate === answer) continue;
    if (chosen.includes(candidate)) continue;
    chosen.push(Math.round(candidate));
    if (chosen.length === 2) break;
  }
  // Nudge outwards only if the realistic errors ran out, keeping them near.
  let offset = 1;
  while (chosen.length < 2) {
    const candidate = answer + offset * (offset % 2 === 0 ? -1 : 1);
    if (candidate > 0 && candidate !== answer && !chosen.includes(candidate)) chosen.push(candidate);
    offset++;
  }
  return [chosen[0] as number, chosen[1] as number];
}

function shuffle3(a: number, b: number, c: number): [number, number, number] {
  const items = [a, b, c];
  for (let i = items.length - 1; i > 0; i--) {
    const j = randInt(0, i);
    [items[i], items[j]] = [items[j] as number, items[i] as number];
  }
  return [items[0] as number, items[1] as number, items[2] as number];
}

function build(tier: Tier, prompt: string, answer: number, wrong: [number, number]): Question {
  return { tier, prompt, answer, choices: shuffle3(answer, wrong[0], wrong[1]) };
}

// ---------------------------------------------------------------------------
// tiers
// ---------------------------------------------------------------------------

/** Tier 1: addition and subtraction within 20. */
function tierOne(): Question {
  const crate = pick(crates);
  if (Math.random() < 0.5) {
    const start = randInt(3, 12);
    const added = randInt(2, 20 - start);
    const answer = start + added;
    return build(
      1,
      `Στο ${crate.holder} έχει ${start} ${crate.many}. Βάζεις άλλα ${added}. Πόσα έχει τώρα;`,
      answer,
      // Reversed operation, then a slip of one either way.
      distractors(answer, [start - added, answer + 1, answer - 2, added]),
    );
  }
  const total = randInt(8, 20);
  const taken = randInt(2, total - 2);
  const answer = total - taken;
  return build(
    1,
    `Το μαγαζί θέλει ${taken} ${crate.many}. Το ${crate.holder} έχει ${total}. Πόσα μένουν στο ${crate.holder};`,
    answer,
    distractors(answer, [total + taken, answer - 1, answer + 2, taken]),
  );
}

/** Tier 2: addition and subtraction within 100, with shop framing. */
function tierTwo(): Question {
  const crate = pick(crates);
  if (Math.random() < 0.45) {
    const start = randInt(14, 58);
    const added = randInt(12, 99 - start);
    const answer = start + added;
    return build(
      2,
      `Το ${crate.holder} έχει ${start} ${crate.many}. Φτάνουν άλλα ${added}. Πόσα έχει τώρα;`,
      answer,
      // Off by ten, the carry forgotten, then the digits swapped.
      distractors(answer, [answer + 10, answer - 10, swapDigits(answer), start - added]),
    );
  }
  const total = randInt(40, 99);
  const wanted = randInt(12, total - 6);
  const answer = total - wanted;
  return build(
    2,
    `Το μαγαζί θέλει ${wanted} ${crate.many}. Το ${crate.holder} σου έχει ${total}. Πόσα μένουν στο ${crate.holder};`,
    answer,
    distractors(answer, [answer + 10, total + wanted, answer - 10, swapDigits(answer)]),
  );
}

/** Tier 3: tables of three to ten, division, and two-step jobs. */
function tierThree(): Question {
  const group = pick(groups);
  const roll = Math.random();

  if (roll < 0.4) {
    const per = randInt(3, 10);
    const count = randInt(3, 10);
    const answer = per * count;
    return build(
      3,
      `Κάθε ${group.unit} κρατάει ${per} ${group.item}. Έχεις ${count} ${group.units}. Πόσα κρατάνε όλα μαζί;`,
      answer,
      // A neighbouring row of the table, then addition instead of multiplication.
      distractors(answer, [per * (count - 1), per * (count + 1), per + count, answer + 10]),
    );
  }

  if (roll < 0.75) {
    const per = randInt(3, 10);
    const count = randInt(3, 10);
    const total = per * count;
    return build(
      3,
      `Έχεις ${total} ${group.item} και ${count} ${group.units}. Πόσα πάνε σε κάθε ${group.unit};`,
      per,
      // The other factor, and the subtraction a child reaches for instead.
      distractors(per, [count, total - count, per + 1, per - 1]),
    );
  }

  const per = randInt(3, 9);
  const count = randInt(3, 8);
  const given = randInt(2, per * count - 3);
  const answer = per * count - given;
  return build(
    3,
    `Μαζεύεις ${count} ${group.units} με ${per} ${group.item} το καθένα. Δίνεις τα ${given}. Πόσα σου μένουν;`,
    answer,
    // The second step forgotten, then the wrong way round.
    distractors(answer, [per * count, per * count + given, answer - 10, answer + 1]),
  );
}

export function makeQuestion(tier: Tier): Question {
  if (tier === 1) return tierOne();
  if (tier === 2) return tierTwo();
  return tierThree();
}

/**
 * Adaptive difficulty. Four right in a row moves up, two wrong moves down.
 * The tier is never shown to the child.
 */
export class TierTracker {
  private tierValue: Tier = 1;
  private streakRight = 0;
  private streakWrong = 0;

  get tier(): Tier {
    return this.tierValue;
  }

  record(correct: boolean): void {
    if (correct) {
      this.streakWrong = 0;
      this.streakRight++;
      if (this.streakRight >= 4 && this.tierValue < 3) {
        this.tierValue = (this.tierValue + 1) as Tier;
        this.streakRight = 0;
      }
      return;
    }
    this.streakRight = 0;
    this.streakWrong++;
    if (this.streakWrong >= 2 && this.tierValue > 1) {
      this.tierValue = (this.tierValue - 1) as Tier;
      this.streakWrong = 0;
    }
  }
}
