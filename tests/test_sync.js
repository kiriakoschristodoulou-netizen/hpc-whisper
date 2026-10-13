// The whole chain with the real sender: typing (with typos and pauses) goes out
// as sound, is spoiled (noise, dropouts, bursts), and the phone's mirror must end
// up exactly equal to what was typed.
const W = require('../modem.js'), C = require('./common.js');
const TEXT = 'Dear Maria, the Jornada still types beautifully after twenty-five years. ' +
             'I am writing this on its keyboard and it appears on my phone without a cable. Kyriakos';
function run(name, band, speed, spoilOpts, seed) {
  C.setSeed(seed);
  const ev = C.script(TEXT);
  const want = C.finalText(ev);
  const { x, info } = C.runSender(ev, band, speed, 50);
  const z = C.spoil(C.to48k(spoilOpts.chip ? C.chip(x, spoilOpts.chip) : x), spoilOpts);
  const m = new W.Mirror(); let frames = 0;
  const rx = new W.Receiver(48000, { onFrame: f => { frames++; m.apply(f); } });
  for (let i = 0; i < z.length; i += 2048) rx.push(z.subarray(i, i + 2048));
  const got = m.text(0, m.L, '#');
  const ok = got === want;
  console.log((ok ? 'ok  ' : 'FAIL') + ' ' + name.padEnd(34) + info.padEnd(42) + 'heard ' + frames + ', unreadable ' + rx.stats.bad + ', gaps ' + rx.stats.gaps + ', erased ' + rx.stats.erased);
  if (!ok) console.log('   got: ' + got + '\n  want: ' + want);
  return ok;
}
let pass = 0, tot = 0, mustFail = 0;
// the harsh dropout cases (a third of the time silent) show the limits; the others must always end right
const cases = [
  ['clean, normal', 4, 1, {}],
  ['clean, fast', 4, 2, {}],
  ['clean, slow, band 18.0', 0, 0, {}],
  ['noise', 4, 1, { noise: 0.03, gain: 0.1 }],
  ['dropouts 15%', 4, 1, { drop: 0.15 }],
  ['dropouts 30%', 4, 1, { drop: 0.30 }],
  ['noise bursts', 4, 1, { burst: 0.15 }],
  ['dropouts + bursts + hum, fast', 4, 2, { drop: 0.15, burst: 0.1, hum: 0.3 }],
  ['ghosts 900 Hz (Jornada 720)', 4, 1, { chip: 43200 }],
  ['ghosts 900 Hz, fast, noise', 4, 2, { chip: 43200, noise: 0.02, gain: 0.1 }],
  ['ghosts 900 Hz, band 18.0, slow', 0, 0, { chip: 43200 }],
  ['ghosts 2100 Hz (another chip)', 4, 1, { chip: 42000 }],
  ['ghosts 600 Hz + bursts', 2, 1, { chip: 43500, burst: 0.1 }],
];
for (const [n, b, s, o] of cases) for (const seed of [1, 2]) {
  tot++;
  const ok = run(n, b, s, o, seed);
  if (ok) pass++; else if (!o.drop) mustFail++;
}
console.log(pass + ' of ' + tot + ' ended exactly right');
if (mustFail) process.exit(1);
