// how long after a key press does the character reach the phone (clean sound)?
const W = require('../modem.js'), C = require('./common.js');
const TEXT = 'Dear Maria, the Jornada still types beautifully after twenty-five years. I am writing this on its keyboard.';
for (const [name, speed] of [['Normal', 1], ['Fast', 2], ['Slow', 0]]) {
  C.setSeed(4);
  const ev = C.script(TEXT, { typos: 0 });
  const { x } = C.runSender(ev, 4, speed, 50);
  const y = C.to48k(x);
  const m = new W.Mirror(), arrive = [];
  const rx = new W.Receiver(48000, { onFrame: f => { m.apply(f); for (let i = 0; i < m.L; i++) if (m.known[i] && arrive[i] === undefined) arrive[i] = rx.n; } });
  for (let i = 0; i < y.length; i += 480) rx.push(y.subarray(i, i + 480));
  // the sender's clock starts after 200 ms of silence (2 buffers) in wmsim
  const lags = ev.map((e, i) => (arrive[i] - 200) - e[0]).filter(v => !isNaN(v)).sort((a, b) => a - b);
  const q = p => (lags[Math.floor(p * (lags.length - 1))] / 1000).toFixed(1);
  console.log(name.padEnd(7) + ' lag: median ' + q(0.5) + ' s, 90% within ' + q(0.9) + ' s, worst ' + q(1) + ' s');
}
