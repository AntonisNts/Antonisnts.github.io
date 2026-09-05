/**
 * One-shot asset preparation.
 *
 * Reads the raw generated art from art-source/ and writes clean, tightly
 * trimmed PNGs with a real alpha channel into public/assets/, plus a
 * manifest.json recording the trim offsets so anchoring stays predictable.
 *
 *   node tools/prep-assets.mjs
 *
 * Nothing in the game reads art-source/. This script is the only bridge.
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { PNG } from 'pngjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(here, '..');
const SRC = path.join(ROOT, 'art-source');
const OUT = path.join(ROOT, 'public', 'assets');

const KEY_GREEN = [0, 255, 0];
const KEY_MAGENTA = [255, 0, 255];
const MAX_DIST = Math.sqrt(3 * 255 * 255);

/**
 * anchorX / anchorY are given in normalised *source* coordinates (0..1 of the
 * untrimmed image). The game resolves them against the trim box, so trimming
 * never moves a sprite.
 */
const JOBS = [
  {
    name: 'striker',
    src: 'striker.png',
    key: KEY_GREEN,
    // Bottom centre: the striker stands on the penalty spot.
    anchorX: 0.5,
    anchorY: 1.0,
    erode: 1,
    feather: 1.1,
    openRadius: 2,
    maxDim: 760,
  },
  {
    name: 'keeper',
    src: 'keeper.png',
    key: KEY_GREEN,
    anchorX: 0.5,
    anchorY: 1.0,
    erode: 1,
    feather: 1.1,
    // Grass and net threads still cling to the gloves; open them away.
    openRadius: 4,
    maxDim: 700,
    // This plate has a stadium band baked in behind the subject; see
    // bandMatte for how the subject is separated from it.
    bandMatte: {
      bandThreshold: 0.2,
      stepTolerance: 0.03,
      whiteDensity: 0.7,
      // Scenery the edge flood cannot reach, in normalised coordinates.
      // Each one only has to land inside a patch; the flood finds its extent.
      patchMajority: 0.88,
      minDensity: 0.62,
      densityRadius: 5,
      // Netting the flood cannot reach: it is walled in by the white barrier.
      clearRects: [[0.283, 0.352, 0.351, 0.451]],
      sceneryPatches: [
        // A fifth value raises how much of a patch's own palette the flood may
        // use. The netting patches sit wholly inside the goal, so they can take
        // nearly all of it; the grass ones brush the kit and stay cautious.
        [0.006, 0.214, 0.212, 0.49, 0.99], // goal frame and net, upper left
        [0.212, 0.23, 0.289, 0.475, 0.99], // netting beside the head
        [0.304, 0.332, 0.348, 0.443, 0.99], // netting behind the near shoulder
        [0.259, 0.554, 0.324, 0.609], // grass below the near arm
        [0.643, 0.522, 0.672, 0.57], // grass beside the far shoulder
        [0.643, 0.573, 0.708, 0.601], // grass below the far arm
        [0.672, 0.609, 0.755, 0.637], // grass beside the far hip
        [0.755, 0.637, 0.902, 0.692], // grass and the loose ball, lower right
      ],
    },
  },
  {
    name: 'ball',
    src: 'ball.png',
    key: KEY_MAGENTA,
    anchorX: 0.5,
    anchorY: 0.5,
    erode: 1,
    feather: 1.0,
    maxDim: 256,
  },
  {
    name: 'goal',
    src: 'goal.png',
    key: KEY_MAGENTA,
    // Anchored on the goal line, centred: the crossbar top and the posts
    // are what the projection cares about.
    anchorX: 0.5,
    anchorY: 1.0,
    // The net mesh is only a couple of pixels wide. Eroding it would delete
    // it outright, so lean on despill instead and feather very lightly.
    erode: 0,
    feather: 0.6,
    // Thin structures (the mesh) are capped below full opacity so the ball
    // reads through the net. Thick structures (posts, bar) stay solid.
    netAlphaCap: 0.72,
    maxDim: 1200,
  },
  {
    name: 'stadium',
    src: 'stadium.png',
    key: null, // full-frame background plate, used as is
    // The plate's own goal is far too small for this camera and would show
    // through our netting, so it is painted out.
    inpaintRects: [[0.392, 0.372, 0.614, 0.676]],
    anchorX: 0.5,
    anchorY: 0.5,
    erode: 0,
    feather: 0,
    maxDim: 1600,
  },
];

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

const clamp01 = (v) => (v < 0 ? 0 : v > 1 ? 1 : v);

function keyDistance(d, i, key) {
  const dr = d[i] - key[0];
  const dg = d[i + 1] - key[1];
  const db = d[i + 2] - key[2];
  return Math.sqrt(dr * dr + dg * dg + db * db) / MAX_DIST;
}

/** Colour distance between two pixels, normalised 0..1. */
function pixelDistance(d, a, b) {
  const dr = d[a] - d[b];
  const dg = d[a + 1] - d[b + 1];
  const db = d[a + 2] - d[b + 2];
  return Math.sqrt(dr * dr + dg * dg + db * db) / MAX_DIST;
}

/**
 * Step 1. Alpha straight from colour distance to the key colour.
 * Inside BG_IN it is certainly background, past BG_OUT certainly foreground,
 * and the band between the two gives a soft edge instead of a jagged cut.
 */
const BG_IN = 0.25;
const BG_OUT = 0.4;

function alphaFromKey(png, key) {
  const { width: w, height: h, data: d } = png;
  const alpha = new Float32Array(w * h);
  for (let p = 0; p < w * h; p++) {
    const dist = keyDistance(d, p * 4, key);
    alpha[p] = clamp01((dist - BG_IN) / (BG_OUT - BG_IN));
  }
  return alpha;
}

/**
 * Step 2a. Flood fill from all four corners over background-ish pixels.
 */
function floodFromEdges(alpha, w, h) {
  const bg = new Uint8Array(w * h);
  const stack = [];
  const push = (x, y) => {
    if (x < 0 || y < 0 || x >= w || y >= h) return;
    const p = y * w + x;
    if (bg[p] || alpha[p] >= 1) return;
    bg[p] = 1;
    stack.push(p);
  };
  push(0, 0);
  push(w - 1, 0);
  push(0, h - 1);
  push(w - 1, h - 1);
  while (stack.length) {
    const p = stack.pop();
    const x = p % w;
    const y = (p / w) | 0;
    push(x - 1, y);
    push(x + 1, y);
    push(x, y - 1);
    push(x, y + 1);
  }
  return bg;
}

/**
 * Step 2b. Clear enclosed key-coloured regions — the gap between an arm and a
 * body never touches an edge, so the corner flood alone leaves a coloured blob
 * sitting in the middle of the sprite.
 */
function clearEnclosed(alpha, bg, w, h) {
  let cleared = 0;
  for (let p = 0; p < w * h; p++) {
    if (bg[p] || alpha[p] >= 0.5) continue;
    // Unvisited background-ish pixel: walk its whole component and clear it.
    const stack = [p];
    bg[p] = 1;
    while (stack.length) {
      const q = stack.pop();
      cleared++;
      const x = q % w;
      const y = (q / w) | 0;
      const nb = [
        x > 0 ? q - 1 : -1,
        x < w - 1 ? q + 1 : -1,
        y > 0 ? q - w : -1,
        y < h - 1 ? q + w : -1,
      ];
      for (const n of nb) {
        if (n < 0 || bg[n] || alpha[n] >= 0.5) continue;
        bg[n] = 1;
        stack.push(n);
      }
    }
  }
  return cleared;
}

/** Coarse RGB bin, used by the band matte's per-patch palettes. */
const PALETTE_BINS = 12;
function colourBin(d, i) {
  return (
    ((d[i] * PALETTE_BINS) >> 8) * PALETTE_BINS * PALETTE_BINS +
    ((d[i + 1] * PALETTE_BINS) >> 8) * PALETTE_BINS +
    ((d[i + 2] * PALETTE_BINS) >> 8)
  );
}

/** Grow a bin set by one bin in every direction, so shading still passes. */
function widenBins(bins) {
  const out = new Set(bins);
  for (const b of bins) {
    const r = (b / (PALETTE_BINS * PALETTE_BINS)) | 0;
    const g = ((b / PALETTE_BINS) | 0) % PALETTE_BINS;
    const bl = b % PALETTE_BINS;
    for (let dr = -1; dr <= 1; dr++) {
      for (let dg = -1; dg <= 1; dg++) {
        for (let db = -1; db <= 1; db++) {
          const rr = r + dr;
          const gg = g + dg;
          const bb = bl + db;
          if (rr < 0 || gg < 0 || bb < 0) continue;
          if (rr >= PALETTE_BINS || gg >= PALETTE_BINS || bb >= PALETTE_BINS) continue;
          out.add((rr * PALETTE_BINS + gg) * PALETTE_BINS + bb);
        }
      }
    }
  }
  return out;
}

/**
 * Optional, and only needed by one plate.
 *
 * The keeper was generated with a stadium band baked in behind the subject, so
 * the key colour only covers the strips above and below it. Inside that band
 * the subject is separated from the scenery by flooding:
 *
 *   - the flood starts at the band's edges and at a few marked scenery
 *     patches that the edges cannot reach, because a mown stripe boundary is
 *     a bigger colour step than the flood is allowed to cross;
 *   - it may only step between neighbouring pixels of near-identical colour,
 *     so it spreads freely across smooth grass and stops dead at a silhouette;
 *   - solid white masses are barriers, so the net cannot leak into the hair;
 *   - what survives, connected to the legs (whose silhouette the key colour
 *     already gave us), is the subject.
 *
 * The marked patches say only "this is scenery" — the silhouette itself is
 * still computed, never traced.
 */
function bandMatte(png, alpha, bg, cfg) {
  const { width: w, height: h, data: d } = png;

  // 1. Find the band: the rows where the key colour has essentially vanished.
  let y0 = 0;
  let y1 = h - 1;
  const keyRatio = (y) => {
    let c = 0;
    for (let x = 0; x < w; x++) if (alpha[y * w + x] < 0.5) c++;
    return c / w;
  };
  while (y0 < h && keyRatio(y0) > cfg.bandThreshold) y0++;
  while (y1 > y0 && keyRatio(y1) > cfg.bandThreshold) y1--;
  y1 += 1;
  if (y1 - y0 < 8) return;

  // 2. Solid white is the subject's hair, and the net is white too, so the
  // open flood is barred from white altogether: it must not walk out of the
  // netting and into the hair. Marked patches may cross the barrier, since
  // their palettes already confine them to the scenery.
  const isWhite = (i) => d[i] > 170 && d[i + 1] > 170 && d[i + 2] > 165;
  const wr = cfg.whiteRadius ?? 5;
  const barrier = new Uint8Array(w * h);
  for (let y = y0; y < y1; y++) {
    for (let x = 0; x < w; x++) {
      const p = y * w + x;
      if (!isWhite(p * 4)) continue;
      let n = 0;
      let t = 0;
      for (let dy = -wr; dy <= wr; dy++) {
        const yy = y + dy;
        if (yy < y0 || yy >= y1) continue;
        for (let dx = -wr; dx <= wr; dx++) {
          const xx = x + dx;
          if (xx < 0 || xx >= w) continue;
          t++;
          if (isWhite((yy * w + xx) * 4)) n++;
        }
      }
      if (n / t > cfg.whiteDensity) barrier[p] = 1;
    }
  }

  // 3. Flood the scenery. `palette`, when set, restricts the flood to one
  // marked patch's own colours.
  let palette = null;
  const scenery = new Uint8Array(w * h);
  const stack = [];
  const seed = (x, y) => {
    if (x < 0 || x >= w || y < y0 || y >= y1) return;
    const p = y * w + x;
    if (scenery[p]) return;
    if (barrier[p] && !palette) return;
    scenery[p] = 1;
    stack.push(p);
  };
  for (let y = y0; y < y1; y++) {
    seed(0, y);
    seed(w - 1, y);
  }
  // Seed against the clean strips, but only where they are confidently
  // background: a soft edge pixel there is half subject, and seeding one lets
  // the flood climb straight up into the kit.
  for (let x = 0; x < w; x++) {
    if (y0 > 0 && alpha[(y0 - 1) * w + x] < 0.05) seed(x, y0);
    if (y1 < h && alpha[y1 * w + x] < 0.05) seed(x, y1 - 1);
  }
  const grow = () => {
    while (stack.length) {
      const p = stack.pop();
      const x = p % w;
      const y = (p / w) | 0;
      const nb = [
        x > 0 ? p - 1 : -1,
        x < w - 1 ? p + 1 : -1,
        y > y0 ? p - w : -1,
        y < y1 - 1 ? p + w : -1,
      ];
      for (const n of nb) {
        if (n < 0 || scenery[n]) continue;
        if (barrier[n] && !palette) continue;
        if (pixelDistance(d, p * 4, n * 4) > cfg.stepTolerance) continue;
        if (palette && !palette.has(colourBin(d, n * 4))) continue;
        scenery[n] = 1;
        stack.push(n);
      }
    }
  };
  grow();
  if (process.env.DUMP_MATTE) {
    let n = 0;
    for (let q = 0; q < w * h; q++) if (scenery[q]) n++;
    console.error('edge flood', n, 'band', y0, y1);
  }

  // Colours we already know belong to the subject, taken for free from the
  // clean strips above and below the band, where the key colour did the work.
  // No marked patch may flood into them, however much of a patch they cover.
  // Sampled clear of the band edges, where a sliver of scenery can survive.
  const known = new Set();
  const margin = cfg.knownSubjectMargin ?? 40;
  for (let y = 0; y < h; y++) {
    if (y > y0 - margin && y < y1 + margin) continue;
    for (let x = 0; x < w; x++) {
      const p = y * w + x;
      if (alpha[p] > 0.9 && !bg[p]) known.add(colourBin(d, p * 4));
    }
  }
  // Not widened: the subject's shadowed skin sits one bin from sunlit grass,
  // and widening would put the grass out of reach of every patch.
  const knownSubject = known;

  // Each marked patch floods under its own palette, taken from the colours
  // that make up most of the patch, minus anything the subject is known to
  // wear. A patch that clips the subject therefore cannot spread into it.
  for (const [rx0, ry0, rx1, ry1, patchMajority] of cfg.sceneryPatches ?? []) {
    const px0 = Math.round(rx0 * w);
    const px1 = Math.round(rx1 * w);
    const py0 = Math.round(ry0 * h);
    const py1 = Math.round(ry1 * h);
    const counts = new Map();
    for (let y = py0; y < py1; y++) {
      for (let x = px0; x < px1; x++) {
        const b = colourBin(d, (y * w + x) * 4);
        counts.set(b, (counts.get(b) ?? 0) + 1);
      }
    }
    const total = Math.max(1, (py1 - py0) * (px1 - px0));
    const majority = new Set();
    let acc = 0;
    for (const [b, c] of [...counts.entries()].sort((a, b2) => b2[1] - a[1])) {
      if (acc / total >= (patchMajority ?? cfg.patchMajority)) break;
      acc += c;
      if (knownSubject.has(b)) continue;
      majority.add(b);
    }
    palette = widenBins(majority);
    for (let y = py0; y < py1; y++) {
      for (let x = px0; x < px1; x++) {
        if (palette.has(colourBin(d, (y * w + x) * 4))) seed(x, y);
      }
    }
    grow();
    palette = null;
  }

  // 4. Keep what is connected to the legs.
  const subject = new Uint8Array(w * h);
  const q = [];
  for (let x = 0; x < w; x++) {
    const p = (y1 - 1) * w + x;
    if (!scenery[p] && !bg[p] && !subject[p]) {
      subject[p] = 1;
      q.push(p);
    }
  }
  while (q.length) {
    const p = q.pop();
    const x = p % w;
    const y = (p / w) | 0;
    const nb = [
      x > 0 ? p - 1 : -1,
      x < w - 1 ? p + 1 : -1,
      y > y0 ? p - w : -1,
      y < y1 - 1 ? p + w : -1,
    ];
    for (const n of nb) {
      if (n < 0 || subject[n] || scenery[n]) continue;
      subject[n] = 1;
      q.push(n);
    }
  }

  // 5. Fill holes — a kit panel that happens to match the crowd's colour must
  // not punch through the torso. A hole containing flooded scenery is real
  // background seen through the subject, so it is left alone.
  const visited = new Uint8Array(w * h);
  for (let y = y0; y < y1; y++) {
    for (let x = 0; x < w; x++) {
      const start = y * w + x;
      if (visited[start] || subject[start]) continue;
      const region = [];
      const rq = [start];
      visited[start] = 1;
      let touchesEdge = false;
      let holdsScenery = false;
      while (rq.length) {
        const p = rq.pop();
        region.push(p);
        const px = p % w;
        const py = (p / w) | 0;
        if (px === 0 || px === w - 1 || py === y0 || py === y1 - 1) touchesEdge = true;
        if (scenery[p]) holdsScenery = true;
        const nb = [
          px > 0 ? p - 1 : -1,
          px < w - 1 ? p + 1 : -1,
          py > y0 ? p - w : -1,
          py < y1 - 1 ? p + w : -1,
        ];
        for (const n of nb) {
          if (n < 0 || visited[n] || subject[n]) continue;
          visited[n] = 1;
          rq.push(n);
        }
      }
      if (!touchesEdge && !holdsScenery) for (const p of region) subject[p] = 1;
    }
  }

  // 5b. Drop stray threads. A net cord or a blade of grass left clinging to
  // the silhouette is two or three pixels wide; every real part of the
  // subject, fingers included, is far thicker. Measure local density and cut
  // what is too thin to be anything but debris, then keep the one blob left.
  if (cfg.minDensity) {
    const dr = cfg.densityRadius ?? 5;
    const thick = new Uint8Array(w * h);
    for (let y = y0; y < y1; y++) {
      for (let x = 0; x < w; x++) {
        const p = y * w + x;
        if (!subject[p]) continue;
        let n = 0;
        let t = 0;
        for (let dy = -dr; dy <= dr; dy++) {
          const yy = y + dy;
          if (yy < y0 || yy >= y1) continue;
          for (let dx = -dr; dx <= dr; dx++) {
            const xx = x + dx;
            if (xx < 0 || xx >= w) continue;
            t++;
            if (subject[yy * w + xx]) n++;
          }
        }
        if (n / t >= cfg.minDensity) thick[p] = 1;
      }
    }
    const kept = new Uint8Array(w * h);
    const kq = [];
    for (let x = 0; x < w; x++) {
      const p = (y1 - 1) * w + x;
      if (thick[p] && !kept[p]) {
        kept[p] = 1;
        kq.push(p);
      }
    }
    while (kq.length) {
      const p = kq.pop();
      const x = p % w;
      const y = (p / w) | 0;
      const nb = [
        x > 0 ? p - 1 : -1,
        x < w - 1 ? p + 1 : -1,
        y > y0 ? p - w : -1,
        y < y1 - 1 ? p + w : -1,
      ];
      for (const n of nb) {
        if (n < 0 || kept[n] || !thick[n]) continue;
        kept[n] = 1;
        kq.push(n);
      }
    }
    // Give the silhouette its outer pixels back, but only next to what stayed.
    for (let r = 0; r < dr; r++) {
      const grownEdge = kept.slice();
      for (let y = y0; y < y1; y++) {
        for (let x = 0; x < w; x++) {
          const p = y * w + x;
          if (kept[p] || !subject[p]) continue;
          if (
            (x > 0 && kept[p - 1]) ||
            (x < w - 1 && kept[p + 1]) ||
            (y > y0 && kept[p - w]) ||
            (y < y1 - 1 && kept[p + w])
          ) {
            grownEdge[p] = 1;
          }
        }
      }
      kept.set(grownEdge);
    }
    subject.set(kept);
  }

  if (process.env.DUMP_MATTE) {
    const dump = new PNG({ width: w, height: h });
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        const p = y * w + x;
        const i = p * 4;
        const inBand = y >= y0 && y < y1;
        const red = inBand && scenery[p];
        const keep = inBand ? subject[p] : alpha[p] > 0.5;
        dump.data[i] = red ? 255 : keep ? d[i] : 90;
        dump.data[i + 1] = red ? 0 : keep ? d[i + 1] : 90;
        dump.data[i + 2] = red ? 0 : keep ? d[i + 2] : 90;
        dump.data[i + 3] = 255;
      }
    }
    fs.writeFileSync(process.env.DUMP_MATTE, PNG.sync.write(dump));
  }

  // 5c. One region of netting sits inside the white barrier that protects the
  // hair, so no flood can reach it. It is cut away outright. This is the only
  // place in the pipeline where a rectangle decides a pixel's fate; it is
  // kept clear of the silhouette, which is still computed everywhere.
  for (const [rx0, ry0, rx1, ry1] of cfg.clearRects ?? []) {
    for (let y = Math.round(ry0 * h); y < Math.round(ry1 * h); y++) {
      for (let x = Math.round(rx0 * w); x < Math.round(rx1 * w); x++) {
        if (y < y0 || y >= y1 || x < 0 || x >= w) continue;
        subject[y * w + x] = 0;
      }
    }
  }

  // 6. Commit the mask for the band.
  for (let y = y0; y < y1; y++) {
    for (let x = 0; x < w; x++) {
      const p = y * w + x;
      alpha[p] = subject[p] ? 1 : 0;
      bg[p] = subject[p] ? 0 : 1;
    }
  }
}

/**
 * Step 3a. Restore the true colour behind the matte.
 *
 * A soft edge pixel is a mix: what the camera recorded is the sprite's own
 * colour blended with the key colour in proportion to the alpha we just
 * derived. Undoing that blend is the difference between a clean sprite and a
 * coloured fringe — and on the netting, where almost every pixel is a soft
 * edge, it is the difference between white mesh and magenta mesh.
 *
 *   recorded = alpha * true + (1 - alpha) * key
 *   true     = (recorded - (1 - alpha) * key) / alpha
 */
function unpremultiplyKey(png, alpha, key, w, h) {
  const d = png.data;
  const greenKey = key[1] > 200;
  for (let p = 0; p < w * h; p++) {
    const a = alpha[p];
    if (a <= 0.02) continue;
    const i = p * 4;

    // Undo the blend wherever the pixel is partly background.
    if (a < 0.995) {
      for (let c = 0; c < 3; c++) {
        const restored = (d[i + c] - (1 - a) * key[c]) / a;
        d[i + c] = restored < 0 ? 0 : restored > 255 ? 255 : Math.round(restored);
      }
    }

    // Then suppress spill everywhere, not only on the soft edge. A net cord
    // two pixels wide is lit by the key colour along its whole length, and
    // reads fully opaque here even though it will be faded later, so an
    // edges-only pass would leave the mesh tinted. Holding the key's own
    // channels down to the one it lacks turns that tint back into the neutral
    // it should be, and leaves every honest colour untouched.
    if (greenKey) {
      const limit = Math.max(d[i], d[i + 2]);
      if (d[i + 1] > limit) d[i + 1] = limit;
    } else {
      const limit = d[i + 1];
      if (d[i] > limit) d[i] = limit;
      if (d[i + 2] > limit) d[i + 2] = limit;
    }
  }
}

/** Step 3b. Erode the alpha mask by n pixels (min filter). */
function erode(alpha, w, h, n) {
  let cur = alpha;
  for (let r = 0; r < n; r++) {
    const next = new Float32Array(w * h);
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        const p = y * w + x;
        let m = cur[p];
        if (x > 0) m = Math.min(m, cur[p - 1]);
        if (x < w - 1) m = Math.min(m, cur[p + 1]);
        if (y > 0) m = Math.min(m, cur[p - w]);
        if (y < h - 1) m = Math.min(m, cur[p + w]);
        next[p] = m;
      }
    }
    cur = next;
  }
  return cur;
}

/** Step 3c. Feather: separable box blur, run twice for a near-Gaussian falloff. */
function feather(alpha, w, h, radius) {
  if (radius <= 0) return alpha;
  const r = Math.max(1, Math.round(radius));
  let cur = alpha;
  for (let pass = 0; pass < 2; pass++) {
    const tmp = new Float32Array(w * h);
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        let sum = 0;
        let n = 0;
        for (let k = -r; k <= r; k++) {
          const xx = x + k;
          if (xx < 0 || xx >= w) continue;
          sum += cur[y * w + xx];
          n++;
        }
        tmp[y * w + x] = sum / n;
      }
    }
    const out = new Float32Array(w * h);
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        let sum = 0;
        let n = 0;
        for (let k = -r; k <= r; k++) {
          const yy = y + k;
          if (yy < 0 || yy >= h) continue;
          sum += tmp[yy * w + x];
          n++;
        }
        out[y * w + x] = sum / n;
      }
    }
    cur = out;
  }
  return cur;
}

/**
 * Keep the net readable. Thin structures (mesh) are capped below full opacity;
 * thick ones (posts, crossbar) are left alone.
 */
function capThinStructures(alpha, w, h, cap) {
  const r = 3;
  const out = Float32Array.from(alpha);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const p = y * w + x;
      if (alpha[p] <= 0) continue;
      let sum = 0;
      let n = 0;
      for (let dy = -r; dy <= r; dy++) {
        const yy = y + dy;
        if (yy < 0 || yy >= h) continue;
        for (let dx = -r; dx <= r; dx++) {
          const xx = x + dx;
          if (xx < 0 || xx >= w) continue;
          sum += alpha[yy * w + xx];
          n++;
        }
      }
      const density = sum / n;
      if (density < 0.55) {
        // Fade smoothly from the cap (isolated mesh) up to full (solid metal).
        const t = clamp01(density / 0.55);
        out[p] = Math.min(alpha[p], cap + (1 - cap) * t * t);
      }
    }
  }
  return out;
}


/**
 * Remove threads left clinging to a sprite.
 *
 * Erode the mask until anything a few pixels wide has snapped, keep the blob
 * that survives, then grow it back inside the original mask. The silhouette
 * comes back exactly as it was; a blade of grass still stuck to a glove does
 * not, and the trim box no longer stretches around it.
 */
function openByReconstruction(alpha, w, h, radius) {
  const solid = new Uint8Array(w * h);
  for (let p = 0; p < w * h; p++) solid[p] = alpha[p] >= 0.5 ? 1 : 0;

  let eroded = solid;
  for (let r = 0; r < radius; r++) {
    const next = new Uint8Array(w * h);
    for (let y = 1; y < h - 1; y++) {
      for (let x = 1; x < w - 1; x++) {
        const p = y * w + x;
        next[p] =
          eroded[p] && eroded[p - 1] && eroded[p + 1] && eroded[p - w] && eroded[p + w] ? 1 : 0;
      }
    }
    eroded = next;
  }

  // Largest surviving blob is the subject.
  const seen = new Uint8Array(w * h);
  let best = null;
  let bestSize = 0;
  for (let start = 0; start < w * h; start++) {
    if (!eroded[start] || seen[start]) continue;
    const region = [start];
    const stack = [start];
    seen[start] = 1;
    while (stack.length) {
      const q = stack.pop();
      const x = q % w;
      const y = (q / w) | 0;
      const nb = [
        x > 0 ? q - 1 : -1,
        x < w - 1 ? q + 1 : -1,
        y > 0 ? q - w : -1,
        y < h - 1 ? q + w : -1,
      ];
      for (const n of nb) {
        if (n < 0 || seen[n] || !eroded[n]) continue;
        seen[n] = 1;
        region.push(n);
        stack.push(n);
      }
    }
    if (region.length > bestSize) {
      bestSize = region.length;
      best = region;
    }
  }
  if (!best) return alpha;

  const kept = new Uint8Array(w * h);
  const queue = [];
  for (const p of best) {
    kept[p] = 1;
    queue.push(p);
  }
  while (queue.length) {
    const p = queue.pop();
    const x = p % w;
    const y = (p / w) | 0;
    const nb = [
      x > 0 ? p - 1 : -1,
      x < w - 1 ? p + 1 : -1,
      y > 0 ? p - w : -1,
      y < h - 1 ? p + w : -1,
    ];
    for (const n of nb) {
      if (n < 0 || kept[n] || !solid[n]) continue;
      kept[n] = 1;
      queue.push(n);
    }
  }

  const out = new Float32Array(w * h);
  for (let p = 0; p < w * h; p++) out[p] = kept[p] ? alpha[p] : 0;
  // Feathered pixels just outside the kept blob belong to it too.
  for (let y = 1; y < h - 1; y++) {
    for (let x = 1; x < w - 1; x++) {
      const p = y * w + x;
      if (out[p] > 0 || alpha[p] <= 0) continue;
      if (kept[p - 1] || kept[p + 1] || kept[p - w] || kept[p + w]) out[p] = alpha[p];
    }
  }
  return out;
}

/**
 * Step 4. Trim the margins, returning the trim box.
 *
 * The test is for real coverage rather than any coverage at all: a single
 * feathered thread left clinging to a sprite would otherwise stretch the box
 * around it, and every placement derived from the box would shift with it.
 */
function trimBox(alpha, w, h, threshold) {
  let x0 = w;
  let y0 = h;
  let x1 = -1;
  let y1 = -1;
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      if (alpha[y * w + x] >= threshold) {
        if (x < x0) x0 = x;
        if (x > x1) x1 = x;
        if (y < y0) y0 = y;
        if (y > y1) y1 = y;
      }
    }
  }
  if (x1 < 0) return { x: 0, y: 0, w, h };
  return { x: x0, y: y0, w: x1 - x0 + 1, h: y1 - y0 + 1 };
}


/**
 * Paint out a rectangle by drawing each row across from its own edges.
 *
 * The background plate came with a goal of its own, far smaller than the one
 * this camera needs, and it would show through our netting. Behind that
 * rectangle the plate is banded crowd and mown grass, so interpolating each
 * row between the colours either side of the box removes the goal without
 * leaving anything a player would notice.
 */
function inpaintRect(png, rect) {
  const { width: w, height: h, data: d } = png;
  const x0 = Math.max(1, Math.round(rect[0] * w));
  const y0 = Math.max(0, Math.round(rect[1] * h));
  const x1 = Math.min(w - 2, Math.round(rect[2] * w));
  const y1 = Math.min(h, Math.round(rect[3] * h));
  const span = x1 - x0;
  if (span <= 1) return;
  for (let y = y0; y < y1; y++) {
    const left = (y * w + (x0 - 1)) * 4;
    const right = (y * w + (x1 + 1)) * 4;
    for (let x = x0; x <= x1; x++) {
      const t = (x - x0) / span;
      const i = (y * w + x) * 4;
      // A touch of noise keeps the fill from banding against the grass.
      const grain = (Math.random() - 0.5) * 5;
      d[i] = clamp255(d[left] * (1 - t) + d[right] * t + grain);
      d[i + 1] = clamp255(d[left + 1] * (1 - t) + d[right + 1] * t + grain);
      d[i + 2] = clamp255(d[left + 2] * (1 - t) + d[right + 2] * t + grain);
    }
  }
}

const clamp255 = (v) => (v < 0 ? 0 : v > 255 ? 255 : Math.round(v));

/** Box-filter downscale in premultiplied alpha, so edges cannot bleed. */
function downscale(png, factor) {
  if (factor >= 1) return png;
  const sw = png.width;
  const sh = png.height;
  const dw = Math.max(1, Math.round(sw * factor));
  const dh = Math.max(1, Math.round(sh * factor));
  const out = new PNG({ width: dw, height: dh });
  const s = png.data;
  const o = out.data;
  for (let y = 0; y < dh; y++) {
    const sy0 = Math.floor((y * sh) / dh);
    const sy1 = Math.max(sy0 + 1, Math.floor(((y + 1) * sh) / dh));
    for (let x = 0; x < dw; x++) {
      const sx0 = Math.floor((x * sw) / dw);
      const sx1 = Math.max(sx0 + 1, Math.floor(((x + 1) * sw) / dw));
      let r = 0;
      let g = 0;
      let b = 0;
      let a = 0;
      let n = 0;
      for (let yy = sy0; yy < sy1; yy++) {
        for (let xx = sx0; xx < sx1; xx++) {
          const i = (yy * sw + xx) * 4;
          const av = s[i + 3] / 255;
          r += s[i] * av;
          g += s[i + 1] * av;
          b += s[i + 2] * av;
          a += av;
          n++;
        }
      }
      const i = (y * dw + x) * 4;
      const am = a / n;
      o[i] = am > 0 ? Math.round(r / n / am) : 0;
      o[i + 1] = am > 0 ? Math.round(g / n / am) : 0;
      o[i + 2] = am > 0 ? Math.round(b / n / am) : 0;
      o[i + 3] = Math.round(am * 255);
    }
  }
  return out;
}

// ---------------------------------------------------------------------------

function run() {
  fs.mkdirSync(OUT, { recursive: true });
  const manifest = {};

  for (const job of JOBS) {
    const png = PNG.sync.read(fs.readFileSync(path.join(SRC, job.src)));
    const { width: w, height: h } = png;
    let alpha;

    for (const rect of job.inpaintRects ?? []) inpaintRect(png, rect);

    if (job.key) {
      alpha = alphaFromKey(png, job.key);
      const bg = floodFromEdges(alpha, w, h);
      clearEnclosed(alpha, bg, w, h);
      if (job.bandMatte) bandMatte(png, alpha, bg, job.bandMatte);
      for (let p = 0; p < w * h; p++) if (bg[p]) alpha[p] = 0;
      unpremultiplyKey(png, alpha, job.key, w, h);
      alpha = erode(alpha, w, h, job.erode);
      alpha = feather(alpha, w, h, job.feather);
      if (job.netAlphaCap) alpha = capThinStructures(alpha, w, h, job.netAlphaCap);
      if (job.openRadius) alpha = openByReconstruction(alpha, w, h, job.openRadius);
    } else {
      alpha = new Float32Array(w * h).fill(1);
    }

    const box = trimBox(alpha, w, h, job.trimThreshold ?? 0.35);
    const trimmed = new PNG({ width: box.w, height: box.h });
    for (let y = 0; y < box.h; y++) {
      for (let x = 0; x < box.w; x++) {
        const sp = (y + box.y) * w + (x + box.x);
        const si = sp * 4;
        const di = (y * box.w + x) * 4;
        trimmed.data[di] = png.data[si];
        trimmed.data[di + 1] = png.data[si + 1];
        trimmed.data[di + 2] = png.data[si + 2];
        trimmed.data[di + 3] = Math.round(clamp01(alpha[sp]) * 255);
      }
    }

    const factor = job.maxDim ? Math.min(1, job.maxDim / Math.max(box.w, box.h)) : 1;
    const final = downscale(trimmed, factor);
    const file = `${job.name}.png`;
    fs.writeFileSync(path.join(OUT, file), PNG.sync.write(final));

    manifest[job.name] = {
      file,
      width: final.width,
      height: final.height,
      // Source frame the anchor was authored against.
      sourceWidth: w,
      sourceHeight: h,
      trim: box,
      scale: factor,
      // Anchor in normalised source coordinates, re-expressed as a fraction of
      // the trimmed sprite so the game can place it without knowing the trim.
      anchor: {
        x: (job.anchorX * w - box.x) / box.w,
        y: (job.anchorY * h - box.y) / box.h,
      },
    };

    const kb = (fs.statSync(path.join(OUT, file)).size / 1024) | 0;
    console.log(
      `${job.name.padEnd(8)} ${String(w).padStart(4)}x${h} -> trim ${box.w}x${box.h} @${box.x},${box.y} -> out ${final.width}x${final.height}  ${kb}kb`
    );
  }

  fs.writeFileSync(path.join(OUT, 'manifest.json'), JSON.stringify(manifest, null, 2));
  console.log('wrote public/assets/manifest.json');
}

run();
