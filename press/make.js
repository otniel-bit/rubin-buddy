// Regenerates the Product Hunt / press gallery images.
//
//   node press/make.js
//
// Authored at 1270x760 and rendered by headless Chrome at 2x, so the output is
// 2540x1520 — comfortably over Product Hunt's 1270x760 minimum.
//
// Everything is composed from the real sprite PNGs in ../frames rather than
// screenshotted. Two reasons: the pixel art stays exact at any size, and a real
// desktop capture would include whatever happened to be behind him.
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const HERE = __dirname;
const FRAMES = path.join(HERE, '..', 'frames');
const CHROME =
  process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

const b64 = (f) =>
  'data:image/png;base64,' + fs.readFileSync(path.join(FRAMES, f)).toString('base64');

const A = {
  idle: b64('idle-0.png'),
  think: b64('think-1.png'),
  stroke: b64('stroke-2.png'),
  look: b64('look-0.png'),
  nod: b64('nod-2.png'),
  icon: b64('menubar.png'),
};

const BASE = `
  :root {
    --paper: #f4f1ea; --ink: #17120f; --faint: #8a8177; --rule: #ddd7cb;
    --desk: #232220; --beard: #f6f3ec;
  }
  * { box-sizing: border-box; margin: 0; }
  html, body { width: 1270px; height: 760px; overflow: hidden; }
  body {
    background: var(--paper); color: var(--ink);
    font: 400 20px/1.5 ui-serif, "Iowan Old Style", Georgia, serif;
    -webkit-font-smoothing: antialiased;
  }
  .sprite { image-rendering: pixelated; display: block; }
  .kicker {
    font-size: 15px; letter-spacing: .16em; text-transform: uppercase;
    color: var(--faint);
  }
  .mono { font-family: ui-monospace, Menlo, Monaco, monospace; }

  /* Faithful rebuild of the in-app bubble: bevelled corners, uniform border,
     outlined tail. The tail is a sibling because clip-path crops children. */
  .bwrap { display: inline-block; }
  .bubble {
    background: var(--beard);
    /* Set explicitly. Inheriting it rendered the text white-on-white on the dark
       composition, where the body colour is the same near-white as the bubble. */
    color: var(--ink);
    border: 5px solid var(--ink);
    font: 400 25px/1.35 ui-monospace, Menlo, Monaco, monospace;
    padding: 15px 20px; white-space: pre-line; text-align: left;
    clip-path: polygon(7px 0, calc(100% - 7px) 0, 100% 7px, 100% calc(100% - 7px),
                       calc(100% - 7px) 100%, 7px 100%, 0 calc(100% - 7px), 0 7px);
  }
  .tail { position: relative; height: 20px; }
  .tail::before, .tail::after {
    content: ""; position: absolute; top: 0; left: 50%; margin-left: -16px;
    width: 0; height: 0;
    border-left: 16px solid transparent; border-right: 16px solid transparent;
  }
  .tail::before { border-top: 20px solid var(--ink); }
  .tail::after  { top: -6px; border-top: 20px solid var(--beard); }
`;

const page = (css, body) =>
  `<!doctype html><meta charset="utf-8"><style>${BASE}${css}</style><body>${body}</body>`;

const bubble = (text) =>
  `<div class="bwrap"><div class="bubble">${text}</div><div class="tail"></div></div>`;

const write = (name, css, body) =>
  fs.writeFileSync(path.join(HERE, name + '.html'), page(css, body));

// ── 1. hero, used as the social preview ─────────────────────────────────────
write('1-hero', `
  body { display: flex; align-items: center; justify-content: center; gap: 100px; }
  .left { flex: none; display: flex; flex-direction: column; align-items: center; }
  h1 { font-size: 122px; line-height: .95; font-weight: 400; letter-spacing: -.02em; }
  .tag { font-size: 35px; line-height: 1.32; margin-top: 28px; }
  .sub { font-size: 24px; color: var(--faint); margin-top: 22px; line-height: 1.5; }
  .url { margin-top: 46px; font-size: 22px; letter-spacing: .04em; }
`, `
  <div class="left">
    ${bubble('Let it breathe.')}
    <img class="sprite" src="${A.idle}" width="286" height="374" alt="">
  </div>
  <div>
    <h1>Rick</h1>
    <p class="tag">An 8-bit buddy who sits on your<br>screen while you work.</p>
    <p class="sub">He watches what Claude Code is doing.<br>Now and then he says something.</p>
    <p class="url mono">rick-buddy.netlify.app</p>
  </div>
`);

// ── 2. the four Claude Code states ──────────────────────────────────────────
const state = (img, label, caption) => `
  <div class="col">
    <img class="sprite" src="${img}" width="156" height="204" alt="">
    <p class="kicker">${label}</p>
    <p class="cap">${caption}</p>
  </div>`;

write('2-states', `
  /* Centred as one block, so the canvas isn't bottom-heavy with dead paper. */
  body { display: flex; flex-direction: column; justify-content: center; padding: 0 84px; }
  h2 { font-size: 54px; font-weight: 400; letter-spacing: -.01em; }
  .lede { font-size: 22px; color: var(--faint); margin-top: 16px; }
  .row { display: flex; margin-top: 66px; }
  .col {
    flex: 1; display: flex; flex-direction: column; align-items: center;
    text-align: center; padding: 0 18px; border-left: 1px solid var(--rule);
  }
  .col:first-child { border-left: 0; }
  .col .kicker { margin-top: 32px; }
  .cap { font-size: 19px; margin-top: 10px; line-height: 1.45; }
`, `
  <h2>He knows what Claude Code is doing.</h2>
  <p class="lede">Six hooks, one word on disk. He reacts in about a fifth of a second.</p>
  <div class="row">
    ${state(A.think, 'Thinking', 'You send a prompt.<br>Hands on the beard.')}
    ${state(A.stroke, 'Working', 'A tool runs.<br>He works the beard.')}
    ${state(A.look, 'Your turn', 'It needs you. Shades up,<br>eyes on you.')}
    ${state(A.nod, 'Done', 'It finishes.<br>One slow nod.')}
  </div>
`);

// ── 3. on your desktop ──────────────────────────────────────────────────────
write('3-desktop', `
  body { background: var(--desk); color: var(--beard); position: relative; }
  /* Suggests the window you're working in, without imitating any application. */
  .pane {
    position: absolute; left: 0; top: 0; bottom: 0; width: 41%;
    background: #1c1b19; border-right: 1px solid #302e2b; padding: 92px 54px 0;
  }
  .pane i { display: block; height: 12px; border-radius: 6px; background: #2b2926; margin-bottom: 30px; }
  .pane i:nth-child(2) { width: 74%; } .pane i:nth-child(3) { width: 88%; }
  .pane i:nth-child(4) { width: 63%; } .pane i:nth-child(5) { width: 80%; }
  .pane i:nth-child(6) { width: 55%; }
  h2 {
    position: absolute; left: 47%; top: 96px; width: 46%;
    font-size: 46px; font-weight: 400; line-height: 1.2;
  }
  h2 small { display: block; font-size: 21px; color: #9a9288; margin-top: 20px; line-height: 1.55; }
  /* High enough that the speech bubble below can't overlap and clip it. */
  .chip {
    position: absolute; left: 47%; top: 238px; display: inline-flex; align-items: center;
    gap: 13px; background: var(--paper); color: var(--ink);
    padding: 11px 19px 11px 15px; border-radius: 9px; font-size: 18px;
  }
  .chip img { image-rendering: pixelated; width: 24px; height: 24px; }
  /* Bottom-right, which is where he actually starts. */
  .guy {
    position: absolute; right: 96px; bottom: 64px;
    display: flex; flex-direction: column; align-items: center;
  }
`, `
  <div class="pane"><i></i><i></i><i></i><i></i><i></i><i></i></div>
  <h2>He lives on your desktop.
    <small>Always on top, never in the way. Drag him anywhere — he remembers
    where you left him.</small>
  </h2>
  <div class="chip"><img src="${A.icon}" alt="">Menu bar: size, chatter, bring him back</div>
  <div class="guy">
    ${bubble('Reduce.\nDon’t produce.')}
    <img class="sprite" src="${A.stroke}" width="182" height="238" alt="">
  </div>
`);

// ── 4. install ──────────────────────────────────────────────────────────────
write('4-install', `
  body { display: flex; flex-direction: column; justify-content: center; padding: 0 96px; position: relative; }
  h2 { font-size: 80px; font-weight: 400; letter-spacing: -.02em; }
  ol { margin: 32px 0 0; padding-left: 30px; font-size: 26px; line-height: 1.8; }
  .term {
    margin-top: 42px; background: var(--ink); color: #e9e4da;
    padding: 26px 30px; border-radius: 10px;
    /* 18px keeps the command on one line; it wrapped mid-word at 21px. */
    font: 400 18px/1.5 ui-monospace, Menlo, Monaco, monospace;
    white-space: nowrap;
  }
  .foot { display: flex; justify-content: space-between; align-items: flex-end; margin-top: 38px; }
  .foot p { font-size: 20px; color: var(--faint); line-height: 1.5; }
  .guy { position: absolute; right: 96px; top: 104px; }
`, `
  <img class="sprite guy" src="${A.look}" width="143" height="187" alt="">
  <h2>One line.</h2>
  <ol>
    <li>Open Terminal.</li>
    <li>Paste this. Press return.</li>
  </ol>
  <div class="term">curl -fsSL https://raw.githubusercontent.com/otniel-bit/rubin-buddy/main/install.sh | sh</div>
  <div class="foot">
    <p>macOS. No Homebrew, no Node, nothing as administrator.<br>Built from source on your machine, so there's nothing unsigned to click past.</p>
    <p class="mono">rick-buddy.netlify.app</p>
  </div>
`);

const names = ['1-hero', '2-states', '3-desktop', '4-install'];
try {
  for (const name of names) {
    execFileSync(
      CHROME,
      [
        '--headless=new', '--disable-gpu', '--hide-scrollbars',
        '--force-device-scale-factor=2', '--window-size=1270,760',
        `--screenshot=${path.join(HERE, name + '.png')}`,
        `file://${path.join(HERE, name + '.html')}`,
      ],
      { stdio: 'ignore' }
    );
    console.log('  ' + name + '.png');
  }
} finally {
  // The HTML files are scaffolding either way — don't strand them on failure.
  for (const name of names) fs.rmSync(path.join(HERE, name + '.html'), { force: true });
}
