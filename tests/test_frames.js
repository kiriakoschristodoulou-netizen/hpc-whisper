// the Pascal sender and the JS encoder must make the same symbols
const W = require('../modem.js'), C = require('./common.js'), fs = require('fs'), cp = require('child_process');
// a JS frame through the JS receiver, every size
let ok = 0;
for (let n = 0; n <= W.MAXLEN; n++) {
  const bytes = Array.from({ length: n }, (_, i) => 32 + (i * 7) % 90);
  const sym = W.encodeFrame({ seq: n, doc: 3, L: 1000 + n, o: 500, bytes });
  const x = W.synth(sym, 48000, 20000, 0.032, 0.1);
  const pad = new Float32Array(48000 * 0.3), z = new Float32Array(pad.length * 2 + x.length); z.set(x, pad.length);
  let got = null; const rx = new W.Receiver(48000, { onFrame: f => got = f });
  rx.push(z);
  if (got && got.bytes.join() === bytes.join() && got.L === 1000 + n && got.o === 500 && got.seq === n && got.doc === 3) ok++;
  else console.log('size', n, 'failed');
}
console.log(ok, 'of', W.MAXLEN + 1, 'sizes read back');
