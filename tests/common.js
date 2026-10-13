// helpers for the tests: run the real handheld sender, move its sound to 48 kHz, spoil it
const fs = require('fs'), cp = require('child_process'), path = require('path');
const TMP = process.env.TMPDIR || '/tmp';
let seed = 12345;
function rnd() { seed = (seed * 16807) % 2147483647; return seed / 2147483647; }
function setSeed(s) { seed = s; }
// a typing script: [ms, code] (code 8 = backspace)
function script(text, opts) {
  opts = opts || {};
  const ev = []; let t = 300;
  for (const ch of text) {
    t += opts.fast ? 60 + rnd() * 80 : 110 + rnd() * 160;
    if (rnd() < (opts.pauses || 0.04)) t += 600 + rnd() * 1500;
    if (rnd() < (opts.typos || 0.03)) { ev.push([t, 'x'.charCodeAt(0)]); t += 150; ev.push([t, 8]); t += 120; }
    ev.push([t, ch.codePointAt(0)]);
  }
  return ev;
}
function finalText(ev) {
  let s = [];
  for (const [, c] of ev) { if (c === 8) s.pop(); else if (c === -1) s = []; else s.push(String.fromCodePoint(c)); }
  return s.join('');
}
function runSender(ev, band, speed, vol) {
  const sp = path.join(TMP, 'whisper-script.txt'), raw = path.join(TMP, 'whisper-out.raw');
  fs.writeFileSync(sp, ev.map(e => Math.round(e[0]) + ' ' + e[1]).join('\n') + '\n');
  const out = cp.execFileSync(path.join(__dirname, 'wmsim'), [sp, raw, String(band), String(speed), String(vol)]).toString();
  const b = fs.readFileSync(raw), x = new Float32Array(b.length / 2);
  for (let i = 0; i < x.length; i++) x[i] = b.readInt16LE(2 * i) / 32768;
  return { x, info: out.trim() };
}
// a handheld sound chip that really runs at another rate, converted crudely (linear
// interpolation, as on the Jornada 720): every tone gets a ghost at (44100 - native) Hz lower
function chip(x, native) {
  const n = Math.floor(x.length * native / 44100), y = new Float32Array(n);
  for (let i = 0; i < n; i++) { const t = i * 44100 / native, k = Math.floor(t), f = t - k; y[i] = (x[k] || 0) * (1 - f) + (x[k + 1] || 0) * f; }
  // ... and plays it at its own rate: hand back 44100-rate samples of that sound (properly resampled)
  const m = Math.floor(n * 44100 / native), z = new Float32Array(m), H = 12;
  for (let i = 0; i < m; i++) {
    const t = i * native / 44100, c = Math.floor(t); let s = 0;
    for (let k = c - H + 1; k <= c + H; k++) { if (k < 0 || k >= n) continue; const d = t - k, w = 0.5 + 0.5 * Math.cos(Math.PI * d / H); s += y[k] * (d === 0 ? 1 : Math.sin(Math.PI * d) / (Math.PI * d)) * w; }
    z[i] = s;
  }
  return z;
}
function to48k(x) {
  const n = Math.floor(x.length * 48000 / 44100), y = new Float32Array(n);
  for (let i = 0; i < n; i++) { const t = i * 44100 / 48000, k = Math.floor(t), f = t - k; y[i] = (x[k] || 0) * (1 - f) + (x[k + 1] || 0) * f; }
  return y;
}
// opts: gain, noise, drop (chance per 300 ms of a total dropout), burst (chance per 100 ms of a loud noise burst)
function spoil(y, o) {
  const z = new Float32Array(y.length), R = 48000;
  let dropLeft = 0, burstLeft = 0;
  for (let i = 0; i < y.length; i++) {
    if (i % (R * 0.3 | 0) === 0 && rnd() < (o.drop || 0)) dropLeft = R * 0.3;
    if (i % (R * 0.1 | 0) === 0 && rnd() < (o.burst || 0)) burstLeft = R * 0.1;
    let v = dropLeft > 0 ? 0 : (o.gain || 0.2) * y[i];
    v += (o.noise || 0.005) * (rnd() * 2 - 1);
    if (burstLeft > 0) v += 0.5 * (rnd() * 2 - 1);
    if (o.hum) v += o.hum * Math.sin(2 * Math.PI * 440 * i / R);
    if (dropLeft > 0) dropLeft--; if (burstLeft > 0) burstLeft--;
    z[i] = v;
  }
  return z;
}
module.exports = { rnd, setSeed, script, finalText, runSender, chip, to48k, spoil };
