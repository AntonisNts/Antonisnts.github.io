// The QR encoder, verified against a reference encoder and a real decoder.
//
// It pulls qrMatrix() OUT OF app/index.html rather than importing a copy, so
// what is tested is what ships. A second copy would have drifted the first
// time someone edited one of them.
//
// Two bugs were found here that were invisible by looking at the picture: the
// format-info second copy was written one cell too far (bit 7 landed on the
// dark module), and the format bits were written LSB-first when placement
// wants MSB-first. In both cases the data was perfect and the code simply
// would not scan -- a decoder never gets as far as the data if it cannot read
// the format. Eyeballing the image would never have caught either.
//
//   npm install            # qrcode (reference) + jsqr (decoder)
//   node qr.js
const fs = require("fs");
const jsQR = require("jsqr");
const QR = require("qrcode");

// --- lift qrMatrix out of the app --------------------------------------------
const src = fs.readFileSync(__dirname + "/../index.html", "utf8");
const start = src.indexOf("function qrMatrix(text) {");
if (start < 0) throw new Error("qrMatrix not found in app/index.html");
// Balance braces from the declaration to find where the function ends.
let depth = 0, end = -1;
for (let i = src.indexOf("{", start); i < src.length; i++) {
  if (src[i] === "{") depth++;
  else if (src[i] === "}") { depth--; if (depth === 0) { end = i + 1; break; } }
}
const qrMatrix = new Function(src.slice(start, end) + "; return qrMatrix;")();

// --- render it the way a camera sees it, then decode -------------------------
function decode(m, scale = 4) {
  const q = 4, n = m.length, size = (n + q * 2) * scale;
  const d = new Uint8ClampedArray(size * size * 4).fill(255);
  for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) {
    const mx = Math.floor(x / scale) - q, my = Math.floor(y / scale) - q;
    const dark = mx >= 0 && my >= 0 && mx < n && my < n && m[my][mx] === 1;
    const i = (y * size + x) * 4;
    d[i] = d[i + 1] = d[i + 2] = dark ? 0 : 255;
  }
  const r = jsQR(d, size, size);
  return r ? r.data : null;
}

// Strip the mask so two encoders can be compared on what they actually encode.
// A different mask is a legitimate tie-break, not a disagreement.
const MASKS = [
  (r, c) => (r + c) % 2 === 0, (r, c) => r % 2 === 0,
  (r, c) => c % 3 === 0, (r, c) => (r + c) % 3 === 0,
  (r, c) => (Math.floor(r / 2) + Math.floor(c / 3)) % 2 === 0,
  (r, c) => ((r * c) % 2) + ((r * c) % 3) === 0,
  (r, c) => (((r * c) % 2) + ((r * c) % 3)) % 2 === 0,
  (r, c) => (((r + c) % 2) + ((r * c) % 3)) % 2 === 0,
];
const ALIGN = [null, [], [6,18], [6,22], [6,26], [6,30], [6,34],
               [6,22,38], [6,24,42], [6,26,46], [6,28,50]];

function readMask(G) {
  const b = [];
  for (let i = 0; i < 15; i++) {
    let r, c;
    if (i < 6) { r = 8; c = i; } else if (i < 8) { r = 8; c = i + 1; }
    else if (i === 8) { r = 7; c = 8; } else { r = 14 - i; c = 8; }
    b.push(G[r][c]);
  }
  return ((parseInt(b.join(""), 2) ^ 0b101010000010010) >> 10) & 0b111;
}

function unmasked(G, ver) {
  const n = G.length, k = readMask(G);
  const res = Array.from({length: n}, () => new Array(n).fill(false));
  const mark = (r0, c0) => { for (let r = -1; r <= 7; r++) for (let c = -1; c <= 7; c++) {
    const rr = r0 + r, cc = c0 + c; if (rr >= 0 && cc >= 0 && rr < n && cc < n) res[rr][cc] = true; } };
  mark(0, 0); mark(0, n - 7); mark(n - 7, 0);
  for (let i = 0; i < n; i++) { res[6][i] = true; res[i][6] = true; }
  for (let i = 0; i < 9; i++) { res[8][i] = true; res[i][8] = true; }
  for (let i = 0; i < 8; i++) { res[8][n - 1 - i] = true; res[n - 1 - i][8] = true; }
  if (ver >= 7) for (let i = 0; i < 18; i++) {
    res[Math.floor(i / 3)][n - 11 + (i % 3)] = true;
    res[n - 11 + (i % 3)][Math.floor(i / 3)] = true;
  }
  for (const a of ALIGN[ver]) for (const b of ALIGN[ver]) {
    if ((a <= 8 && b <= 8) || (a <= 8 && b >= n - 9) || (a >= n - 9 && b <= 8)) continue;
    for (let r = -2; r <= 2; r++) for (let c = -2; c <= 2; c++) res[a + r][b + c] = true;
  }
  const out = [];
  for (let r = 0; r < n; r++) { const row = [];
    for (let c = 0; c < n; c++) row.push(res[r][c] ? null : (G[r][c] ^ (MASKS[k](r, c) ? 1 : 0)));
    out.push(row); }
  return out;
}

// --- the suite ---------------------------------------------------------------
let pass = 0, fail = 0;
const ok = (n, c, d) => { c ? (pass++, console.log("  ok   " + n))
                            : (fail++, console.log("  FAIL " + n + (d ? " — " + d : ""))); };

// Byte-mode capacity at EC level M, per version.
const CAP = [0, 14, 26, 42, 62, 84, 106, 122, 152, 180, 213];

for (let v = 1; v <= 10; v++) {
  const t = "A".repeat(CAP[v]);
  const M = qrMatrix(t);
  ok(`v${v} is the version chosen for ${CAP[v]} characters`,
     M && M.length === 17 + v * 4, M ? "got v" + (M.length - 17) / 4 : "null");
  if (!M) continue;

  ok(`v${v} round-trips through a decoder`, decode(M) === t);

  // Same payload through a reference encoder. The mask may legitimately
  // differ, so compare what is underneath it rather than the picture.
  const ref = QR.create([{ data: t, mode: "byte" }], { errorCorrectionLevel: "M" });
  const n = ref.modules.size, rd = ref.modules.data;
  const R = []; for (let r = 0; r < n; r++) { const row = [];
    for (let c = 0; c < n; c++) row.push(rd[r * n + c] ? 1 : 0); R.push(row); }
  const A = unmasked(R, v), B = unmasked(M, v);
  let diff = 0;
  for (let r = 0; r < n; r++) for (let c = 0; c < n; c++)
    if (A[r][c] !== null && A[r][c] !== B[r][c]) diff++;
  ok(`v${v} encodes identically to the reference, mask aside`, diff === 0, diff + " cells");
}

ok("one character past capacity is refused rather than truncated",
   qrMatrix("A".repeat(214)) === null);

// The shapes that actually go on a tag.
for (const u of [
  "https://paystamp.app/stamp/Ap3DljlE_HGYMKueGWQ6Tedb",
  "https://paystamp.app/stamp/Ap3DljlE_HGYMKueGWQ6Tedb?n=36d9aecb2e",
  "https://paystamp-staging.netlify.app/stamp/Ap3DljlE_HGYMKueGWQ6Tedb?n=36d9aecb2e",
]) ok("a real tag URL round-trips (" + u.length + " chars)", decode(qrMatrix(u)) === u);

ok("a Greek school name round-trips", (() => {
  const t = "https://paystamp.app/stamp/Χορός";
  return decode(qrMatrix(t)) === t;
})());

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
