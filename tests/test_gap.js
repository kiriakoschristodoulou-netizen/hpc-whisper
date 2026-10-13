// the handheld's sound may stall for a moment (a gap: every tone after it comes later)
const W = require('../modem.js'), C = require('./common.js');
let pass = 0, tot = 0;
for (const ms of [48, 32, 20]) for (const gap of [5, 15, 25, 40, 60]) for (const where of [0.2, 0.5, 0.85]) {
  C.setSeed(gap * 13 + ms);
  const bytes = Array.from({ length: 40 }, () => 32 + (C.rnd() * 90 | 0));
  const x = Array.from(W.synth(W.encodeFrame({ seq: 9, doc: 2, L: 40, o: 0, bytes }), 48000, 20000, ms / 1000, 0.1));
  const cut = Math.round(x.length * where);
  const y = new Float32Array(x.slice(0, cut).concat(new Array(48 * gap).fill(0), x.slice(cut)));
  const z = new Float32Array(48000 * 0.3 * 2 + y.length + 48000 * 6); z.set(y, 14400);
  for (let i = 0; i < z.length; i++) z[i] += 0.003 * (C.rnd() * 2 - 1);
  let got = null; const rx = new W.Receiver(48000, { onFrame: f => got = f });
  rx.push(z); tot++;
  if (got && got.bytes.join() === bytes.join()) pass++; else console.log('lost: ' + ms + ' ms symbols, gap ' + gap + ' ms at ' + where);
}
console.log(pass + ' of ' + tot + ' frames with a gap read correctly');
if (pass !== tot) process.exit(1);
