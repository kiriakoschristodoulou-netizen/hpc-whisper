// The return channel: the phone's acknowledgement frame, through a modelled handheld microphone
// (offset, noise, gain that climbs, any rate near 43.2 kHz), read by handheld/ackrx.pas.
const W = require('../modem.js'), fs = require('fs'), cp = require('child_process'), path = require('path');
let seed = 99; const rnd = () => ((seed = (seed * 1664525 + 1013904223) >>> 0) / 4294967296);
const gauss = () => { let s = 0; for (let i = 0; i < 6; i++) s += rnd(); return (s - 3) * Math.SQRT2; };
let pass = 0, tot = 0;
const check = (name, ok, info) => { tot++; if (ok) pass++; console.log((ok ? 'ok    ' : 'FAIL  ') + name + (info ? '  ' + info : '')); };

function record(name, acks, o) {
  const R = o.rate || 43204, n = Math.round(R * (2 + acks.length * 2.5));
  const x = new Float32Array(n);
  acks.forEach((a, i) => {
    const s = W.synth(W.ackSymbols(a[0], a[1], a[2], a[3]), R, W.ACK_BAND, W.ACK_SPEED, 1), at = Math.round(R * (1 + i * 2.5));
    const len = s.length;
    for (let j = 0; j < len; j++) {
      // the gain of the microphone climbs by o.climb dB over the first 300 ms
      const t = j / R, g = Math.pow(10, -(o.climb || 0) * Math.max(0, 1 - t / 0.3) / 20);
      x[at + j] += s[j] * g;
    }
  });
  const out = Buffer.alloc(2 * n);
  for (let j = 0; j < n; j++) {
    const v = 843 + o.amp * 32768 * x[j] + o.noise * gauss();
    out.writeInt16LE(Math.max(-32768, Math.min(32767, Math.round(v))), 2 * j);
  }
  const f = path.join(process.env.TMPDIR || '/tmp', 'ack-' + name + '.raw'); fs.writeFileSync(f, out);
  const txt = cp.execFileSync(path.join(__dirname, 'acksim'), [f, '43210']).toString().split('\n');
  return txt.filter(l => l.startsWith('ack ')).map(l => l.split(' ').slice(1).map(Number));
}

const A = [[7, 0, 0, 0], [7, 123, 0, 0xABC], [200, 4567, 15, 0x123], [3, 15999, 9, 0xFFF]];
{
  const r = record('clean', A, { amp: 0.01, noise: 3 });
  check('clean: all four acknowledgements found, in order', r.length === 4 && r.every((v, i) => v[1] === A[i][0] && v[2] === A[i][1] && v[3] === A[i][2] && v[4] === A[i][3]), JSON.stringify(r));
}
{
  const r = record('rate', A, { amp: 0.003, noise: 3, rate: 43224, climb: 25 });
  check('real rate 43,224, gain climbing 25 dB, quiet (-50 dBFS): all found', r.length === 4 && r.every((v, i) => v[1] === A[i][0] && v[2] === A[i][1] && v[3] === A[i][2] && v[4] === A[i][3]), JSON.stringify(r));
}
{
  const r = record('rate2', A, { amp: 0.003, noise: 3, rate: 43190, climb: 25 });
  check('real rate 43,190: all found', r.length === 4, JSON.stringify(r));
}
{
  const r = record('silence', [], { amp: 0.01, noise: 20 });
  check('noise only: nothing found', r.length === 0, JSON.stringify(r));
}
{
  // noise strong enough to spoil symbols: the Reed-Solomon code and the check must still give the right values, or nothing
  let good = 0, wrong = 0, none = 0;
  for (let k = 0; k < 12; k++) {
    const a = [[k * 17 % 250, 1000 + k * 977, k * 11 % 16, (k * 977) & 0xFFF]];
    const r = record('noisy', a, { amp: 0.0012, noise: 14 });
    if (r.length === 1 && r[0][1] === a[0][0] && r[0][2] === a[0][1] && r[0][3] === a[0][2] && r[0][4] === a[0][3]) good++; else if (r.length) wrong++; else none++;
  }
  check('noisy: never a wrong value', wrong === 0, 'right ' + good + ', nothing ' + none + ', wrong ' + wrong);
  check('noisy: mostly right', good >= 8, good + ' of 12');
}
{
  let good = 0, wrong = 0, none = 0, fixed = 0;
  for (let k = 0; k < 20; k++) {
    const a = [[k * 13 % 250, 500 + k * 733, k * 7 % 16, (k * 311) & 0xFFF]];
    const r = record('harsh', a, { amp: 0.0012, noise: 30 });
    if (r.length === 1 && r[0][1] === a[0][0] && r[0][2] === a[0][1] && r[0][3] === a[0][2] && r[0][4] === a[0][3]) { good++; if (r[0][5]) fixed++; } else if (r.length) wrong++; else none++;
  }
  check('harsh noise: never a wrong value (the check byte and Reed-Solomon)', wrong === 0, 'right ' + good + ' (' + fixed + ' needed corrections), nothing ' + none + ', wrong ' + wrong);
}
console.log(pass + ' of ' + tot + ' checks passed');
process.exit(pass === tot ? 0 : 1);
