// the keyboard's Java receiver must read the same sound exactly as the page's JS receiver
const W = require('../modem.js'), C = require('./common.js'), fs = require('fs'), cp = require('child_process'), path = require('path');
const TEXT = 'Typing on the Jornada, read by the keyboard: does Java agree with JavaScript? Yes, it should.';
const out = path.join(process.env.TMPDIR || '/tmp', 'whisper-java.raw');
let pass = 0, tot = 0;
for (const [name, b, s, o] of [['clean', 4, 1, {}], ['fast + noise', 2, 2, { noise: 0.02, gain: 0.1 }], ['dropouts', 4, 1, { drop: 0.12 }], ['bursts', 3, 0, { burst: 0.1 }],
                               ['ghosts 900 Hz', 4, 1, { chip: 43200 }], ['ghosts 2100 Hz, fast', 1, 2, { chip: 42000, noise: 0.01 }]]) {
  C.setSeed(7);
  const ev = C.script(TEXT);
  const sx = C.runSender(ev, b, s, 50).x;
  const z = C.spoil(C.to48k(o.chip ? C.chip(sx, o.chip) : sx), o);
  const buf = Buffer.alloc(z.length * 2);
  for (let i = 0; i < z.length; i++) buf.writeInt16LE(Math.max(-32767, Math.min(32767, Math.round(z[i] * 32767))), 2 * i);
  fs.writeFileSync(out, buf);
  // JS reads the same 16-bit samples
  const y = new Float32Array(z.length); for (let i = 0; i < z.length; i++) y[i] = buf.readInt16LE(2 * i) / 32768;
  const m = new W.Mirror(); const rx = new W.Receiver(48000, { onFrame: f => m.apply(f) });
  for (let i = 0; i < y.length; i += 2048) rx.push(y.subarray(i, i + 2048));
  const js = m.text(0, m.L, '#');
  const res = cp.execFileSync('java', ['-cp', path.join(__dirname, 'java', 'classes'), 'Decode', out]).toString().split('\n');
  const java = res[1];
  tot++;
  const ok = java === js;
  if (ok) pass++;
  console.log((ok ? 'same ' : 'DIFF ') + name.padEnd(14) + res[0].padEnd(30) + (js === C.finalText(ev) ? 'complete' : 'with gaps'));
  if (!ok) console.log('  js:   ' + js + '\n  java: ' + java);
}
console.log(pass + ' of ' + tot + ' identical');
if (pass !== tot) process.exit(1);
