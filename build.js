// Builds the sprite frames the Swift overlay loads, plus a preview sheet.
const fs = require('fs');
const path = require('path');
const { encodePNG } = require('./png');
const {
  OUT_W, OUT_H, ANIMATIONS, MENU_ICON, rasterize, rasterizeMask, withRim,
} = require('./sprite');

const OUT = path.join(__dirname, 'frames');
fs.mkdirSync(OUT, { recursive: true });
for (const f of fs.readdirSync(OUT)) fs.unlinkSync(path.join(OUT, f));

// The rim is applied here rather than in the pose data, so every animation gets
// it for free and none of the row strings have to account for it.
const rimmed = {};
const manifest = {};
for (const [name, anim] of Object.entries(ANIMATIONS)) {
  rimmed[name] = anim.frames.map((frame) => withRim(frame.rows));
  manifest[name] = {
    next: anim.next ?? null,
    shades: anim.shades ?? 'down',
    transition: anim.transition ?? false,
    from: anim.from ?? anim.shades ?? 'down',
    frames: anim.frames.map((frame, i) => {
      const file = `${name}-${i}.png`;
      const { width, height, data } = rasterize(rimmed[name][i], 1);
      fs.writeFileSync(path.join(OUT, file), encodePNG(width, height, data));
      return { file, hold: frame.hold };
    }),
  };
}
fs.writeFileSync(
  path.join(OUT, 'manifest.json'),
  JSON.stringify({ width: OUT_W, height: OUT_H, animations: manifest }, null, 2)
);

// 2x so it's crisp at 16pt on a retina menu bar.
{
  const { width, height, data } = rasterizeMask(MENU_ICON, 2);
  fs.writeFileSync(path.join(OUT, 'menubar.png'), encodePNG(width, height, data));
}

// --- preview contact sheet --------------------------------------------------
// Split background: dark on the left, light on the right, so the rim can be
// judged against both in one look.

const SCALE = 8;
const GAP = 8;
const names = Object.keys(ANIMATIONS);
const cols = Math.max(...names.map((n) => ANIMATIONS[n].frames.length));
const cellW = OUT_W * SCALE + GAP;
const cellH = OUT_H * SCALE + GAP;
const sheetW = cols * cellW + GAP;
const sheetH = names.length * cellH + GAP;
const sheet = Buffer.alloc(sheetW * sheetH * 4);

const DARK = [0x25, 0x24, 0x22];
const LIGHT = [0xe8, 0xe5, 0xdf];
for (let y = 0; y < sheetH; y++) {
  for (let x = 0; x < sheetW; x++) {
    const base = x < sheetW / 2 ? DARK : LIGHT;
    // Faint checker so full transparency is still distinguishable.
    const bump = (((x / 8) | 0) + ((y / 8) | 0)) % 2 === 0 ? 8 : 0;
    const i = (y * sheetW + x) * 4;
    sheet[i] = base[0] + bump;
    sheet[i + 1] = base[1] + bump;
    sheet[i + 2] = base[2] + bump;
    sheet[i + 3] = 255;
  }
}

names.forEach((name, row) => {
  rimmed[name].forEach((rows, col) => {
    const { width, height, data } = rasterize(rows, SCALE);
    const ox = GAP + col * cellW;
    const oy = GAP + row * cellH;
    for (let y = 0; y < height; y++) {
      for (let x = 0; x < width; x++) {
        const s = (y * width + x) * 4;
        const a = data[s + 3];
        if (a === 0) continue;
        const t = ((oy + y) * sheetW + (ox + x)) * 4;
        // Source-over, so the translucent rim shows what it actually does.
        for (let c = 0; c < 3; c++) {
          sheet[t + c] = Math.round((data[s + c] * a + sheet[t + c] * (255 - a)) / 255);
        }
      }
    }
  });
});

fs.writeFileSync(path.join(__dirname, 'preview.png'), encodePNG(sheetW, sheetH, sheet));

const total = names.reduce((a, n) => a + ANIMATIONS[n].frames.length, 0);
console.log(`${total} frames @ ${OUT_W}x${OUT_H} -> frames/  |  preview.png ${sheetW}x${sheetH}`);
console.log(
  names
    .map((n) => `${n}:${ANIMATIONS[n].frames.length}f${ANIMATIONS[n].next ? `>${ANIMATIONS[n].next}` : ''}`)
    .join('  ')
);
