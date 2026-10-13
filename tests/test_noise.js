// no false text from noise and loud audible sound, and how fast the receiver runs
const W = require('../modem.js'), C = require('./common.js');
let frames = 0;
const rx = new W.Receiver(48000, { onFrame: () => frames++ });
const z = new Float32Array(4800); const t0 = Date.now();
for (let k = 0; k < 600; k++) {
  for (let i = 0; i < z.length; i++) z[i] = 0.3 * (C.rnd() * 2 - 1) + 0.5 * Math.sin(2 * Math.PI * (200 + k) * i / 48000);
  rx.push(z);
}
const ms = Date.now() - t0;
console.log('60 s of noise and sound: false frames ' + frames + ', unreadable ' + rx.stats.bad + '; processed in ' + (ms / 1000).toFixed(1) + ' s (' + (60000 / ms).toFixed(1) + 'x real time)');
