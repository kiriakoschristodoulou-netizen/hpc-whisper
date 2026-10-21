// Return Test: the phone's test signal goes through a modelled handheld microphone (offset, noise, automatic gain,
// a block timing error); handheld/retlib.pas must decode the symbols and count the wrong ones.
const P = require('../retplan.js'), fs = require('fs'), cp = require('child_process'), path = require('path');
const REAL = 43204, CLAIM = 44100, FS = REAL;
let seed = 4242; const rnd = () => ((seed = (seed * 1664525 + 1013904223) >>> 0) / 4294967296);
const gauss = () => { let s = 0; for (let i = 0; i < 6; i++) s += rnd(); return (s - 3) * Math.SQRT2; };
let pass = 0, tot = 0;
const check = (name, ok, info) => { tot++; if (ok) pass++; console.log((ok ? 'ok    ' : 'FAIL  ') + name + (info ? '  ' + info : '')); };
const DC = 843;

function run(name, o) {
  const orig = P.segments;
  P.segments = () => orig().map(s => s[2] === 4000 ? s : [s[0] + (o.shift || 0), ...s.slice(1)]);
  const x = P.render(FS, hz => [[hz, (hz === 4000 ? 20000 : o.sc) * Math.pow(10, (o.tilt ? -o.tilt * (hz - 17000) / 3000 : 0) / 20)]]);
  P.segments = orig;
  const y = new Float32Array(x.length); let g = 1, env = 0;
  const att = 1 - Math.exp(-1 / (0.02 * FS)), rel = 1 - Math.exp(-1 / (0.3 * FS)), dec = Math.exp(-1 / (0.03 * FS));
  for (let i = 0; i < x.length; i++) {
    if (o.agc) {
      const a = Math.abs(x[i]); env = a > env ? a : env * dec;
      const gt = Math.min(o.maxg || 1, 2500 / Math.max(env, 1)); g += (gt - g) * (gt < g ? att : rel);
    }
    y[i] = x[i] * g;
  }
  const pre = Math.round(2.3 * REAL), n = pre + y.length + 4 * REAL, out = Buffer.alloc(2 * n);
  for (let j = 0; j < n; j++) {
    let v = j >= pre && j - pre < y.length ? y[j - pre] : 0;
    v += DC + o.noise * gauss();
    out.writeInt16LE(Math.max(-32768, Math.min(32767, Math.round(v))), 2 * j);
  }
  const f = path.join(process.env.TMPDIR || '/tmp', 'ret-' + name + '.raw'); fs.writeFileSync(f, out);
  const txt = cp.execFileSync(path.join(__dirname, 'retsim'), [f, String(CLAIM)]).toString().split('\n');
  const R = { blk: [] };
  for (const l of txt) {
    const w = l.split(' ');
    if (w[0] === 'ok') R.ok = +w[1]; else if (w[0] === 'err') R.err = l; else if (w[0] === 'rate100') R.rate = +w[1] / 100;
    else if (w[0] === 'dc') R.dc = +w[1]; else if (w[0] === 'blk') R.blk[+w[1]] = w.slice(2).map(Number);
  }
  R.txt = txt; return R;
}
// blk: [off, errs, early, margMed, margWorst, lvl, pre0, pre100, pre300]

{
  const R = run('clean', { sc: 20000, noise: 0.3 });
  check('analysis ran', R.ok === 1, R.err || '');
  check('real rate found', Math.abs(R.rate - REAL) / REAL < 0.0005, R.rate + '');
  check('offset found', Math.abs(R.dc - DC) <= 3, R.dc + '');
  check('clean signal: every symbol of every block right', R.blk.every(b => b[1] === 0), JSON.stringify(R.blk.map(b => b[1])));
  check('margins are large (worst over 12 dB)', R.blk.every(b => b[4] > 120), JSON.stringify(R.blk.map(b => b[4] / 10)));
}
{
  const R = run('shift', { sc: 20000, noise: 0.3, shift: 22, agc: true });
  check('blocks found 22 ms after where the markers say (with automatic gain)', R.blk.every(b => b[1] === 0), JSON.stringify(R.blk.map(b => b[1])));
  check('the shift is measured', R.blk.every(b => Math.abs(b[0] - 22) <= 3), JSON.stringify(R.blk.map(b => b[0])));
}
{
  const R = run('noisy', { sc: 800, noise: 1500 });
  const e = R.blk.map(b => b[1]);
  check('noisy: loud blocks (90 %) are still right', e[0] + e[1] + e[2] === 0, JSON.stringify(e));
  check('noisy: quiet fast blocks have errors', e[8] > 3, 'errors at 22 %, 20 ms: ' + e[8]);
  check('noisy: slower is better (22 %: 48 ms fewer errors than 20 ms)', e[6] < e[8], e[6] + ' < ' + e[8]);
  const compact = R.txt.filter(l => l.startsWith('$ ')).map(l => l.slice(2));
  check('the report for the phone is short (under 1,900 characters)', compact.join('\n').length < 1900, compact.join('\n').length + ' characters');
  check('the verdict names the speeds', R.txt.some(l => /^# At 90 % volume.*clean down to/.test(l)));
}
{
  const n = 43204 * 30, b = Buffer.alloc(2 * n); for (let j = 0; j < n; j++) b.writeInt16LE(Math.round(0.3 * gauss()), 2 * j);
  const f = path.join(process.env.TMPDIR || '/tmp', 'ret-empty.raw'); fs.writeFileSync(f, b);
  const t = cp.execFileSync(path.join(__dirname, 'retsim'), [f, '44100']).toString();
  check('silence: reported as a failure with a reason', /^ok 0/m.test(t) && /marker/.test(t));
}
console.log(pass + ' of ' + tot + ' checks passed');
process.exit(pass === tot ? 0 : 1);
