/**
 * On-screen copy. The game ships in Greek; the English column is the brief's
 * wording, kept beside it so the two never drift apart.
 *
 * British spelling in the English column, and no exclamation marks anywhere
 * except on the goal shout.
 */
export type Strings = {
  loading: string;
  firstShotHint: string;
  penaltyLabel: (index: number, total: number) => string;
  goal: string;
  savedCorrect: string;
  savedWrong: string;
  offTarget: string;
  answerWas: (answer: number) => string;
  endGoals: (goals: number, total: number) => string;
  endMaths: (correct: number, total: number) => string;
  continueButton: string;
  tapToStart: string;
  savesLabel: (saves: number) => string;
  coins: string;
};

const el: Strings = {
  loading: 'Προθέρμανση',
  firstShotHint: 'Τράβα πίσω για σημάδι. Άσε το για σουτ.',
  penaltyLabel: (index, total) => `ΠΕΝΑΛΤΙ ${index} ΑΠΟ ${total}`,
  goal: 'ΓΚΟΛ!',
  savedCorrect: 'Ωραία επιλογή, ωραία απόκρουση.',
  savedWrong: 'Όχι αυτό.',
  offTarget: 'Άστοχο, ξαναχτύπα το.',
  answerWas: (answer) => `Η απάντηση ήταν ${answer}.`,
  endGoals: (goals, total) => `${goals} γκολ από ${total}`,
  endMaths: (correct, total) => `Μαθηματικά: ${correct} στα ${total} σωστά`,
  continueButton: 'Πίσω στο νησί',
  tapToStart: 'Άγγιξε για να ξεκινήσεις',
  savesLabel: (saves) => `Αποκρούσεις: ${saves}`,
  coins: 'Νομίσματα',
};

const en: Strings = {
  loading: 'Warming up',
  firstShotHint: 'Drag back to aim. Release to shoot.',
  penaltyLabel: (index, total) => `PENALTY ${index} OF ${total}`,
  goal: 'GOAL!',
  savedCorrect: 'Great choice, great save.',
  savedWrong: 'Not that one.',
  offTarget: 'Off target, take it again.',
  answerWas: (answer) => `The answer was ${answer}.`,
  endGoals: (goals, total) => `${goals} goals from ${total}`,
  endMaths: (correct, total) => `Maths: ${correct} of ${total} correct`,
  continueButton: 'Back to the island',
  tapToStart: 'Tap to start',
  savesLabel: (saves) => `Saves: ${saves}`,
  coins: 'Coins',
};

export const locales = { el, en } as const;
export type LocaleName = keyof typeof locales;

export function pickLocale(name?: string | null): Strings {
  return name && name in locales ? locales[name as LocaleName] : el;
}
