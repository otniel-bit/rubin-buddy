// Rick-Rubin-inspired 8-bit buddy: sprite data + rasterizer.
//
// Sprite grid is 24 x 32. Rows are built by concatenating repeated runs so
// column counts can't silently drift — buildRows() asserts every row width.
//
// Design notes: the read at this size comes almost entirely from silhouette,
// so the proportions are pushed. 4 rows of scalp against 16 rows of beard.
// Arms are one shade lighter than the torso ('n' vs 'b') so hands read as
// attached to something instead of floating. The beard tip is deliberately
// uneven — a clean triangle turns the shoulders into tuxedo lapels.
//
// Every gesture is a small one. He breathes, he nods, he strokes the beard, he
// pushes the shades up onto his head to look at you. Nothing bounces.

const W = 24;
const H = 32;

const PALETTE = {
  '.': null,                 // transparent
  k: [0x17, 0x12, 0x0f],     // outline
  s: [0xe8, 0xc0, 0x99],     // skin
  h: [0xf7, 0xdc, 0xbb],     // scalp highlight
  d: [0xc9, 0x99, 0x6e],     // skin shadow
  w: [0xf6, 0xf3, 0xec],     // beard light
  g: [0xd3, 0xcd, 0xc0],     // beard shadow
  b: [0x1f, 0x1c, 0x1c],     // black tee
  n: [0x33, 0x2f, 0x2c],     // sleeve / arm
  f: [0x56, 0x50, 0x4a],     // sunglasses frame
  l: [0x0e, 0x0c, 0x0b],     // lens
  r: [0xd9, 0x77, 0x57],     // Claude accent
  // Rim light, added around the silhouette by withRim(). Translucent on
  // purpose: against a dark desktop it lifts him off the background, against a
  // light one it all but disappears. An opaque rim reads as a sticker outline.
  o: [0xf6, 0xf3, 0xec, 0x9c],
};

const _ = (n) => '.'.repeat(n);
const c = (ch, n) => ch.repeat(n);

// --- head -------------------------------------------------------------------
// Rows 4-8 all share a 12px interior at cols 6-17, which is what lets the
// shades slide up the face without any special-casing.

const SKULL = _(9) + c('k', 6) + _(9);
const FACE = [
  /* 2 */ _(7) + c('k', 2) + c('s', 6) + c('k', 2) + _(7),
  /* 3 */ _(6) + 'k' + c('s', 2) + c('h', 3) + c('s', 5) + 'k' + _(6),
  /* 4 */ _(5) + 'k' + c('s', 2) + c('h', 2) + c('s', 6) + c('d', 2) + 'k' + _(5),
  /* 5 */ _(5) + 'k' + c('s', 10) + c('d', 2) + 'k' + _(5),
  /* 6 */ _(5) + 'k' + c('s', 8) + c('d', 4) + 'k' + _(5),
];
const BROW = _(5) + 'k' + c('s', 9) + c('d', 3) + 'k' + _(5);
const CHEEK = _(5) + 'k' + c('s', 10) + c('d', 2) + 'k' + _(5);
const EYES = _(5) + 'k' + c('s', 2) + c('k', 2) + c('s', 4) + c('k', 2) + c('s', 2) + 'k' + _(5);
const SHADES = _(5) + 'k' + 'f' + c('l', 4) + 'ff' + c('l', 4) + 'f' + 'k' + _(5);
// Row 3 is only 10 wide, so the crown needs its own narrower band. Mixing the
// two is what makes the pushed-up shades read as tilted rather than flat.
const SHADES_NARROW = _(6) + 'k' + 'f' + c('l', 3) + 'ff' + c('l', 3) + 'f' + 'k' + _(6);
const BEARD_TOP = [
  /* 9  */ _(5) + 'k' + c('w', 2) + c('s', 8) + c('w', 2) + 'k' + _(5),
  /* 10 */ _(5) + 'k' + c('w', 3) + c('s', 2) + c('d', 2) + c('s', 2) + c('w', 3) + 'k' + _(5),
  /* 11 */ _(4) + 'k' + c('w', 6) + c('g', 2) + c('w', 6) + 'k' + _(4),
  /* 12 */ _(4) + 'k' + c('w', 5) + c('g', 4) + c('w', 5) + 'k' + _(4),
  /* 13 */ _(4) + 'k' + c('w', 14) + 'k' + _(4),
];

// `glassesY` is the top row of the two-row shades band; 7 is worn, 3 is pushed
// up onto the crown. `eyes`: 'none' (hidden behind the shades), 'open' (a 2x2
// block on row 7), 'closed' (the same block dropped to row 8 — lowered lids).
function headRows({ glassesY = 7, eyes = 'none' } = {}) {
  const rows = [
    _(W),                                 // 0 — padding
    SKULL,                                // 1
    ...FACE,                              // 2-6
    eyes === 'open' ? EYES : BROW,         // 7
    eyes === 'closed' ? EYES : CHEEK,      // 8
    ...BEARD_TOP,                         // 9-13
  ];
  if (glassesY !== null) {
    const bandFor = (y) => (y === 3 ? SHADES_NARROW : SHADES);
    rows[glassesY] = bandFor(glassesY);
    rows[glassesY + 1] = bandFor(glassesY + 1);
  }
  return rows;
}

// --- body -------------------------------------------------------------------
// Body rows share an 18px interior between the outlines at cols 2 and 21.
// Arms occupy the outer 2 columns of that interior.
const body = (interior) => _(2) + 'k' + interior + 'k' + _(2);

const BEARD_TIP = [
  /* 23 */ body(c('b', 7) + c('w', 4) + c('b', 7)),
  /* 24 */ body(c('b', 8) + c('g', 2) + c('b', 8)),
];

const LEGS = [
  /* 25 */ body(c('b', 18)),
  /* 26 */ _(4) + 'k' + c('b', 14) + 'k' + _(4),
  /* 27 */ _(5) + 'k' + c('b', 4) + 'k' + _(2) + 'k' + c('b', 4) + 'k' + _(5),
  /* 28 */ _(5) + 'k' + c('b', 4) + 'k' + _(2) + 'k' + c('b', 4) + 'k' + _(5),
  /* 29 */ _(5) + 'k' + c('s', 4) + 'k' + _(2) + 'k' + c('s', 4) + 'k' + _(5),
  /* 30 */ _(5) + c('k', 6) + _(2) + c('k', 6) + _(5),
  /* 31 */ _(W),
];

// Arms hanging, hands at the hips.
const BODY_ARMS_DOWN = [
  /* 14 */ body(c('n', 2) + c('w', 14) + c('n', 2)),
  /* 15 */ body(c('n', 2) + c('w', 14) + c('n', 2)),
  /* 16 */ body(c('n', 2) + c('w', 14) + c('n', 2)),
  /* 17 */ body(c('n', 2) + 'b' + c('w', 12) + 'b' + c('n', 2)),
  /* 18 */ body(c('n', 2) + 'b' + c('w', 12) + 'b' + c('n', 2)),
  /* 19 */ body(c('n', 2) + c('b', 2) + c('w', 10) + c('b', 2) + c('n', 2)),
  /* 20 */ body(c('n', 2) + c('b', 3) + c('w', 8) + c('b', 3) + c('n', 2)),
  /* 21 */ body(c('s', 2) + c('b', 3) + c('w', 8) + c('b', 3) + c('s', 2)),
  /* 22 */ body(c('s', 2) + c('b', 4) + c('w', 6) + c('b', 4) + c('s', 2)),
  ...BEARD_TIP,
  ...LEGS,
];

// Both hands come up onto the beard — the "let it breathe" pose.
const BODY_HANDS_UP = [
  /* 14 */ body(c('n', 2) + c('w', 14) + c('n', 2)),
  /* 15 */ body(c('n', 2) + c('w', 14) + c('n', 2)),
  /* 16 */ body(c('n', 2) + c('w', 14) + c('n', 2)),
  /* 17 */ body(c('n', 2) + 'b' + c('w', 12) + 'b' + c('n', 2)),
  /* 18 */ body(c('n', 2) + 'b' + c('w', 12) + 'b' + c('n', 2)),
  /* 19 */ body(c('n', 2) + c('s', 2) + c('w', 10) + c('s', 2) + c('n', 2)),
  /* 20 */ body(c('n', 2) + c('s', 2) + 'b' + c('w', 8) + 'b' + c('s', 2) + c('n', 2)),
  /* 21 */ body(c('n', 2) + c('b', 3) + c('w', 8) + c('b', 3) + c('n', 2)),
  /* 22 */ body(c('n', 2) + c('b', 4) + c('w', 6) + c('b', 4) + c('n', 2)),
  ...BEARD_TIP,
  ...LEGS,
];

const HEAD_BAND_END = 13; // last row that moves when he nods

function buildRows(head, bodyRows, label) {
  const rows = [...head, ...bodyRows];
  if (rows.length !== H) throw new Error(`${label}: ${rows.length} rows, expected ${H}`);
  rows.forEach((row, y) => {
    if (row.length !== W) throw new Error(`${label} row ${y}: width ${row.length}, expected ${W}`);
    for (const ch of row) {
      if (!(ch in PALETTE)) throw new Error(`${label} row ${y}: unknown palette char "${ch}"`);
    }
  });
  return rows;
}

// --- pose composition -------------------------------------------------------

const blank = () => Array.from({ length: H }, () => _(W));

// Shift a slice of rows down by n, leaving the rest in place.
function shiftBand(rows, from, to, n) {
  const out = rows.slice();
  for (let y = to; y >= from; y--) {
    const src = y - n;
    out[y] = src >= from ? rows[src] : _(W);
  }
  return out;
}

const breathe = (rows) => shiftBand(rows, 0, H - 1, 1);

// Paint `over` on top of `under`, transparent pixels letting `under` show.
function overlay(under, over) {
  return under.map((row, y) =>
    row
      .split('')
      .map((ch, x) => (over[y][x] === '.' ? ch : over[y][x]))
      .join('')
  );
}

// Draw a small patch at (x, y). '.' in the patch leaves the sprite alone.
function stamp(rows, x, y, patch) {
  const out = rows.slice();
  patch.forEach((line, i) => {
    const ry = y + i;
    if (ry < 0 || ry >= H) return;
    let row = out[ry];
    for (let j = 0; j < line.length; j++) {
      const rx = x + j;
      if (line[j] === '.' || rx < 0 || rx >= W) continue;
      row = row.substring(0, rx) + line[j] + row.substring(rx + 1);
    }
    out[ry] = row;
  });
  return out;
}

// A little Claude-orange spark, for the thinking pose.
function sparkLayer(y0) {
  const rows = blank();
  const put = (y, x, ch) => {
    if (y < 0 || y >= H) return;
    rows[y] = rows[y].substring(0, x) + ch + rows[y].substring(x + 1);
  };
  put(y0, 20, 'r');
  put(y0 + 1, 19, 'r');
  put(y0 + 1, 21, 'r');
  put(y0 + 2, 20, 'r');
  return rows;
}

// --- poses ------------------------------------------------------------------

const SHADES_ON = headRows({ glassesY: 7, eyes: 'none' });

const standing = buildRows(SHADES_ON, BODY_ARMS_DOWN, 'standing');
const handsOnBeard = buildRows(SHADES_ON, BODY_HANDS_UP, 'handsOnBeard');

// Sitting cross-legged, hands on knees, beard pooling into the lap. The head
// is the standing head, dropped so he reads as grounded rather than shrunk;
// shades stay on — they always stay on.
const sitting = (() => {
  const wide = (interior) => _(1) + 'k' + interior + 'k' + _(1); // 20px interior
  const rows = [
    ...Array(8).fill(_(W)),                 // 0-7
    ...SHADES_ON.slice(1),                  // 8-20: skull through beard top
    /* 21 */ body(c('n', 2) + c('w', 14) + c('n', 2)),
    /* 22 */ body(c('n', 2) + c('w', 14) + c('n', 2)),
    /* 23 */ body('n' + c('b', 2) + c('w', 12) + c('b', 2) + 'n'),
    /* 24 */ wide(c('n', 2) + c('s', 2) + c('w', 12) + c('s', 2) + c('n', 2)),
    /* 25 */ wide(c('b', 3) + c('s', 2) + c('w', 10) + c('s', 2) + c('b', 3)),
    /* 26 */ wide(c('b', 6) + c('w', 3) + c('g', 2) + c('w', 3) + c('b', 6)),
    /* 27 */ wide(c('b', 20)),
    /* 28 */ wide(c('b', 6) + c('s', 3) + c('b', 2) + c('s', 3) + c('b', 6)),
    /* 29 */ _(2) + c('k', 20) + _(2),
    ...Array(2).fill(_(W)),                 // 30-31
  ];
  if (rows.length !== H) throw new Error(`sitting: ${rows.length} rows`);
  rows.forEach((row, y) => {
    if (row.length !== W) throw new Error(`sitting row ${y}: width ${row.length}`);
  });
  return rows;
})();

const wearing = (glassesY, eyes) =>
  buildRows(headRows({ glassesY, eyes }), BODY_ARMS_DOWN, `shades@${glassesY}`);

// One hand working its way down the beard. A bare 2x2 skin block reads as a
// smudge on all that white, so the hand is outlined and the dark sleeve runs
// back to the shoulder at col 20 — the arm is what you actually see.
const strokePatch = (x) => {
  const sleeve = 21 - (x + 2);
  return ['kk' + _(sleeve), 'ss' + c('n', sleeve), 'ss' + c('n', sleeve), 'kk' + _(sleeve)];
};

// The idle right hand at the hip is painted out — that arm is up here now.
const strokeFrame = (x, y) =>
  stamp(stamp(standing, 19, 21, ['nn', 'nn']), x, y, strokePatch(x));

// --- animations -------------------------------------------------------------
// `next`      animation to settle into once a one-shot finishes; null loops.
// `shades`    where the shades are once this animation ends: 'up' or 'down'.
// `transition`/`from`  marks the two animations that move the shades between
//             those positions. The player inserts one automatically when a
//             requested animation's shade position doesn't match the current
//             one, so nothing ever hard-cuts from bare-eyed to shaded.

const ANIMATIONS = {
  // Waiting. The whole body settles a pixel, then rises.
  idle: {
    next: null,
    shades: 'down',
    frames: [
      { rows: standing, hold: 16 },
      { rows: breathe(standing), hold: 16 },
    ],
  },

  // Deep listening. Hands on the beard, spark drifting up.
  think: {
    next: null,
    shades: 'down',
    frames: [
      { rows: overlay(handsOnBeard, sparkLayer(4)), hold: 10 },
      { rows: overlay(breathe(handsOnBeard), sparkLayer(3)), hold: 10 },
      { rows: overlay(handsOnBeard, sparkLayer(2)), hold: 10 },
      { rows: overlay(breathe(handsOnBeard), sparkLayer(1)), hold: 10 },
    ],
  },

  // Working the material. One hand strokes down the beard, following its taper.
  stroke: {
    next: null,
    shades: 'down',
    frames: [
      { rows: strokeFrame(14, 11), hold: 9 },
      { rows: strokeFrame(14, 13), hold: 9 },
      { rows: strokeFrame(13, 16), hold: 9 },
      { rows: strokeFrame(13, 18), hold: 9 },
    ],
  },

  // That's the one. Head dips while the body stays put. Slow on purpose: at
  // the old tempo the whole gesture was 0.6s once and nobody ever saw it.
  nod: {
    next: 'idle',
    shades: 'down',
    frames: [
      { rows: standing, hold: 8 },
      { rows: shiftBand(standing, 0, HEAD_BAND_END, 1), hold: 8 },
      { rows: shiftBand(standing, 0, HEAD_BAND_END, 2), hold: 16 },
      { rows: shiftBand(standing, 0, HEAD_BAND_END, 1), hold: 8 },
    ],
  },

  // Shades slide up onto the crown. He wants to see you properly.
  glasses: {
    next: 'look',
    transition: true,
    from: 'down',
    shades: 'up',
    frames: [
      { rows: wearing(7, 'none'), hold: 3 },
      { rows: wearing(6, 'closed'), hold: 3 },
      { rows: wearing(5, 'open'), hold: 3 },
      { rows: wearing(3, 'open'), hold: 5 },
    ],
  },

  // And back down. Same beats in reverse — he's done looking at you.
  unglasses: {
    next: 'idle',
    transition: true,
    from: 'up',
    shades: 'down',
    frames: [
      { rows: wearing(3, 'open'), hold: 3 },
      { rows: wearing(5, 'open'), hold: 3 },
      { rows: wearing(6, 'closed'), hold: 3 },
      { rows: wearing(7, 'none'), hold: 4 },
    ],
  },

  // Settling down to sit. Quick — the sitting is the point, not the descent.
  sitdown: {
    next: 'meditate',
    shades: 'down',
    frames: [
      { rows: breathe(standing), hold: 5 },
      { rows: sitting, hold: 5 },
    ],
  },

  // His own practice. Cross-legged, slower breath than idle — meditation
  // should read as deeper stillness, not a seated version of waiting.
  meditate: {
    next: null,
    shades: 'down',
    frames: [
      { rows: sitting, hold: 28 },
      { rows: breathe(sitting), hold: 28 },
    ],
  },

  // And back up.
  standup: {
    next: 'idle',
    shades: 'down',
    frames: [
      { rows: sitting, hold: 4 },
      { rows: breathe(standing), hold: 4 },
    ],
  },

  // Shades up, eyes on you. Blinks now and then. This is "your turn".
  look: {
    next: null,
    shades: 'up',
    frames: [
      { rows: wearing(3, 'open'), hold: 40 },
      { rows: breathe(wearing(3, 'open')), hold: 40 },
      { rows: breathe(wearing(3, 'closed')), hold: 3 },
      { rows: wearing(3, 'open'), hold: 20 },
    ],
  },
};

// --- menu bar icon ----------------------------------------------------------
// A 16x16 silhouette: dome, a clear band for the shades, beard tapering to a
// point. Rendered as a black-and-alpha mask and used as an AppKit template
// image, so macOS recolours it for light and dark menu bars.
const MENU_ICON = [
  '................',
  '......####......',
  '....########....',
  '...##########...',
  '...##########...',
  '...#........#...',
  '...##########...',
  '..############..',
  '..############..',
  '..############..',
  '...##########...',
  '...##########...',
  '....########....',
  '.....######.....',
  '......####......',
  '................',
];

function rasterizeMask(rows, scale) {
  const gridH = rows.length;
  const gridW = rows[0].length;
  rows.forEach((row, y) => {
    if (row.length !== gridW) throw new Error(`icon row ${y}: width ${row.length}`);
  });
  const w = gridW * scale;
  const h = gridH * scale;
  const buf = Buffer.alloc(w * h * 4, 0);
  for (let y = 0; y < gridH; y++) {
    for (let x = 0; x < gridW; x++) {
      if (rows[y][x] === '.') continue;
      for (let sy = 0; sy < scale; sy++) {
        for (let sx = 0; sx < scale; sx++) {
          const i = ((y * scale + sy) * w + (x * scale + sx)) * 4;
          buf[i + 3] = 255;  // black, fully opaque — template images use alpha
        }
      }
    }
  }
  return { width: w, height: h, data: buf };
}

// --- rim light --------------------------------------------------------------

const RIM_PAD = 1;
const OUT_W = W + RIM_PAD * 2;
const OUT_H = H + RIM_PAD * 2;

/// Pad by one pixel all round, then set every transparent pixel touching the
/// silhouette to the rim colour. 8-connected, so diagonal steps down the beard
/// taper and around the dome get covered too — 4-connected leaves gaps exactly
/// on the sloped edges that most need separating from the background.
///
/// The pad is what makes this safe: the sprite grid reaches row 31 on the
/// breathing frames, so without it the rim under his feet would clip.
function withRim(rows) {
  const pad = '.'.repeat(RIM_PAD);
  const blankRow = '.'.repeat(OUT_W);
  const padded = [
    ...Array(RIM_PAD).fill(blankRow),
    ...rows.map((row) => pad + row + pad),
    ...Array(RIM_PAD).fill(blankRow),
  ];

  return padded.map((row, y) =>
    row
      .split('')
      .map((ch, x) => {
        if (ch !== '.') return ch;
        for (let dy = -1; dy <= 1; dy++) {
          for (let dx = -1; dx <= 1; dx++) {
            if (dx === 0 && dy === 0) continue;
            const n = padded[y + dy]?.[x + dx];
            if (n && n !== '.' && n !== 'o') return 'o';
          }
        }
        return ch;
      })
      .join('')
  );
}

// --- rasterizing ------------------------------------------------------------

function rasterize(rows, scale) {
  const gridH = rows.length;
  const gridW = rows[0].length;
  const w = gridW * scale;
  const h = gridH * scale;
  const buf = Buffer.alloc(w * h * 4, 0);
  for (let y = 0; y < gridH; y++) {
    for (let x = 0; x < gridW; x++) {
      const rgb = PALETTE[rows[y][x]];
      if (!rgb) continue;
      for (let sy = 0; sy < scale; sy++) {
        for (let sx = 0; sx < scale; sx++) {
          const i = ((y * scale + sy) * w + (x * scale + sx)) * 4;
          buf[i] = rgb[0];
          buf[i + 1] = rgb[1];
          buf[i + 2] = rgb[2];
          buf[i + 3] = rgb[3] ?? 255;
        }
      }
    }
  }
  return { width: w, height: h, data: buf };
}

module.exports = {
  W, H, OUT_W, OUT_H, PALETTE, ANIMATIONS, MENU_ICON, rasterize, rasterizeMask, withRim,
};
