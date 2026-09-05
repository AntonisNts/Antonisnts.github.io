# Penalty Sums

A penalty shootout where the answer to a maths question decides which part of
the goal you have to hit. One self-contained minigame from the Questlings
world: it owns its own assets, loop and canvas, and a hub can launch it later
by serving this folder.

It plays in Greek. British English is kept alongside in `src/strings.ts` so the
two never drift apart; add `?lang=en` to see it.

## Running it

```sh
npm install
npm run prep      # once, and again whenever the art in art-source/ changes
npm run dev
```

`npm run build` type-checks and writes `dist/`. `npm run preview` serves that
build, and `node tools/playtest.mjs` drives a full round through it headlessly.

Add `?debug=1` for an overlay showing flight time, ball speed, the keeper's
decision and the projected landing point.

## Layout

| Path | What it is |
| --- | --- |
| `art-source/` | The raw generated plates. Nothing in the game reads these. |
| `tools/prep-assets.mjs` | Turns those plates into clean PNGs with alpha. |
| `public/assets/` | The prepared sprites and their `manifest.json`. Generated. |
| `src/config.ts` | Every constant that decides how the game feels. |
| `src/maths.ts` | Question generation, difficulty tiers, plausible wrong answers. |
| `src/ball.ts`, `src/keeper.ts` | The shot and the dive. |
| `src/render.ts` | All drawing, in one place. |
| `src/game.ts` | The round and its rules. |

## The asset pipeline

`npm run prep` is a one-shot script. It removes each plate's key colour by
colour distance rather than exact match, floods from the edges *and* clears
enclosed key-coloured regions, undoes the key's contribution to every soft
edge, erodes and feathers the mask, trims to a tight box, and records the trim
offsets in `manifest.json` so anchoring stays predictable. The netting is
deliberately left below full opacity so the ball reads through it.

Two plates needed more than that, and both are handled in the script rather
than by hand-editing the art:

- **The keeper** was generated with a stadium band baked in behind the subject,
  so the key colour only covers the strips above and below it. Inside that band
  the subject is separated by a flood that may only step between neighbouring
  pixels of near-identical colour, seeded from the band's edges and from a few
  marked scenery patches the edges cannot reach. Solid white is a barrier, so
  the netting cannot leak into the hair. The silhouette is computed, never
  traced; the marked patches only say "this is scenery".
- **The stadium** came with a goal of its own, far too small for this camera,
  which would have shown through our netting. It is painted out by interpolating
  each row across the box it occupied.

## Two places the brief and the maths disagreed

Both are flagged in `config.ts` where they bite:

- **Shot speed.** The brief asks for 18–30 m/s *and* a flight time of
  0.55–0.95s. Over an eleven metre run those give 0.61s down to 0.37s. Flight
  time is what decides how the shot feels, so it won: the range is 12.9–20 m/s,
  which lands at 0.85s for the softest shot and 0.55s for the hardest.
- **Draw order.** The brief puts the keeper behind the goal and net. The keeper
  stands in front of the goal line, so it is drawn over the netting instead. The
  ball still sits between the keeper and the striker, and once it has crossed
  the line the netting is drawn over it again, so a goal is visibly behind the
  net.

## The mascot

The sixth plate never arrived, so the sideline mascot is drawn from shapes in
`Renderer.drawCreature`. Drop a prepared `creature.png` into `public/assets/`
(and add it to the manifest via `tools/prep-assets.mjs`) and the art takes over
with no other change.

## Sound

Every cue the game needs — kick, net, save, crowd bed, cheer, groan, coin,
whistle — is called from the moment it happens. The sounds themselves are
synthesised placeholders; swapping each one for a decoded sample is a change
inside `src/audio.ts` and nothing else.
