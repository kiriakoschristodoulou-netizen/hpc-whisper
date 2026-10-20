// Mic Scan: the phone's test signal goes through a modelled handheld microphone (response, ghosts, automatic gain, noise,
// a rate that is not the claimed one); handheld/scanlib.pas must find back what the model did.
const P = require('../scanplan.js'), fs = require('fs'), cp = require('child_process'), path = require('path');
const REAL = 43230, CLAIM = 44100, FS = REAL;   // the signal is made straight at the microphone's real rate
let seed = 12345; const rnd = () => ((seed = (seed * 1664525 + 1013904223) >>> 0) / 4294967296);
const gauss = () => { let s = 0; for (let i = 0; i < 6; i++) s += rnd(); return (s - 3) * Math.SQRT2; };
let pass = 0, tot = 0;
const check = (name, ok, info) => { tot++; if (ok) pass++; console.log((ok ? 'ok    ' : 'FAIL  ') + name + (info ? '  ' + info : '')); };

// the microphone's response in dB: flat to 8 kHz, then falling to -45 at 18 kHz and -55 at 21.5 kHz
const H = hz => hz <= 8000 ? 0 : hz <= 18000 ? -45 * (hz - 8000) / 10000 : -45 - 10 * (hz - 18000) / 3500;
const GH = 0.3;                                   // ghost: 900 Hz below, 0.3 of the tone

function run(name, agc) {
  const SC = 20000;
  const x = P.render(FS, hz => [[hz, SC * Math.pow(10, H(hz) / 20)], [hz - 900, GH * SC * Math.pow(10, H(hz) / 20)]]);
  // automatic gain: attack 60 ms time constant when the level is over a threshold, recovery 1.5 s
  const gain = new Float32Array(x.length); let g = 1, env = 0;
  const att = 1 - Math.exp(-1 / (0.06 * FS)), rel = Math.exp(1 / (1.5 * FS));
  const y = new Float32Array(x.length);
  for (let i = 0; i < x.length; i++) {
    if (agc) {
      const a = Math.abs(x[i] * g);
      env = a > env ? a : env * (1 - 1 / (0.05 * FS));
      if (env > 800) g *= (1 - att * 0.5); else g = Math.min(1, g * rel);
      g = Math.max(g, 0.01);
    }
    gain[i] = g; y[i] = x[i] * g;
  }
  // the recording: 2.3 s before the phone starts, the signal, 4 s after; noise 0.3 counts
  const pre = Math.round(2.3 * REAL), n = pre + y.length + 4 * REAL, out = Buffer.alloc(2 * n);
  for (let j = 0; j < n; j++) {
    let v = j >= pre && j - pre < y.length ? y[j - pre] : 0;
    v += 0.3 * gauss();
    out.writeInt16LE(Math.max(-32768, Math.min(32767, Math.round(v))), 2 * j);
  }
  const f = path.join(process.env.TMPDIR || '/tmp', 'scan-' + name + '.raw'); fs.writeFileSync(f, out);
  const txt = cp.execFileSync(path.join(__dirname, 'scansim'), [f, String(CLAIM)]).toString().split('\n');
  const R = { tone: [], agc: [], burst: [] };
  for (const l of txt) {
    const w = l.split(' ');
    if (w[0] === 'ok') R.ok = +w[1]; else if (w[0] === 'err') R.err = l;
    else if (w[0] === 'rate100') R.rate = +w[1] / 100; else if (w[0] === 'mark') R.mark = [+w[1], +w[2]];
    else if (w[0] === 'noise') R.noise = +w[1];
    else if (w[0] === 'tone') R.tone[+w[1]] = w.slice(2).map(Number);
    else if (w[0] === 'agc') R.agc[+w[1]] = w.slice(2).map(Number);
    else if (w[0] === 'burst') R.burst[+w[1]] = [+w[2], +w[3]];
    else if (w[0] === 'usable') R.usable = [+w[1], +w[2]];
    else if (w[0] === '#' && /Real sampling|Usable/.test(l)) console.log('      ' + l.slice(2));
  }
  R.txt = txt; return { R, gain, SC, txt };
}

// ---- 1. a steady microphone ----
{
  const { R, SC } = run('flat', false);
  check('analysis ran', R.ok === 1, R.err || '');
  check('real rate found', Math.abs(R.rate - REAL) / REAL < 0.0005, R.rate + ' (model ' + REAL + ')');
  let worst = 0, wi = 0;
  for (let i = 0; i < P.NTONE; i++) {
    const truth = 200 * Math.log10(P.TONE_AMP * SC * Math.pow(10, H(P.toneHz(i)) / 20) / 32768);
    const d = Math.abs(R.tone[i][0] - truth); if (d > worst) { worst = d; wi = i; }
  }
  check('all 43 tone levels within 1.5 dB', worst <= 15, 'worst ' + (worst / 10).toFixed(1) + ' dB at ' + P.toneHz(wi) + ' Hz');
  let gw = 0;
  for (let i = 4; i < P.NTONE; i++) { const d = Math.abs(R.tone[i][3] - 200 * Math.log10(GH)); if (R.tone[i][0] - R.tone[i][1] > 150 && d > gw) gw = d; }
  check('ghost 900 Hz below found at -10.5 dB', gw <= 20, 'worst deviation ' + (gw / 10).toFixed(1) + ' dB');
  check('no ghost above', R.tone[20][4] < -200, 'level ' + R.tone[20][4] / 10);
  let fall = 0; for (let i = 0; i < P.NTONE; i++) fall = Math.max(fall, Math.abs(R.tone[i][2]));
  check('steady microphone: no fall', fall <= 15, 'largest ' + fall / 10 + ' dB');
  check('noise floor near -100 dBFS', R.noise < -950 && R.noise > -1100, R.noise / 10 + ' dBFS');
  // tones are heard 20 dB over background while  H > about -63 dB re 0.5*SC ... find the model's own limit
  let hiTruth = 0; for (let i = 0; i < P.NTONE; i++) { const a = P.TONE_AMP * SC * Math.pow(10, H(P.toneHz(i)) / 20); if (20 * Math.log10(a / (0.3 * 1.41)) >= 20) hiTruth = P.toneHz(i); }
  check('top of the usable range', Math.abs(R.usable[1] - hiTruth) <= 500, R.usable[1] + ' (model ' + hiTruth + ')');
  check('background at one frequency, measured like a tone (about -128 dBFS)', Math.abs(R.tone[10][1] - (-1280)) <= 40, R.tone[10][1] / 10 + ' dBFS');
  const compact = R.txt.filter(l => l.startsWith('$ ')).map(l => l.slice(2));
  check('the report for the phone is short (under 1,700 characters)', compact.join('\n').length < 1700, compact.join('\n').length + ' characters');
  check('short bursts all seen', R.burst.every(b => b[1] >= 5), JSON.stringify(R.burst));
  check('burst level near the steady tone (>= -3 dB)', R.burst.slice(1).every(b => b[0] > -30), JSON.stringify(R.burst.map(b => b[0] / 10)));
}

// ---- 2. a microphone with automatic gain ----
{
  const { R, gain } = run('agc', true);
  check('analysis ran (AGC)', R.ok === 1, R.err || '');
  check('real rate found (AGC)', Math.abs(R.rate - REAL) / REAL < 0.0005, R.rate + '');
  // the model's own gain at the times the analysis looked at, for the 3 kHz test at 90 %
  const g0 = 0, st = P.AGC_AT0 / 1000, at = ms => Math.round((st + ms / 1000) * FS);
  const mg = i => 20 * Math.log10(gain[at(i * 50 + 25)]);
  const ref = Math.max(mg(0), mg(1), mg(2));
  const want = [0, 1, 4, 9, 19, 38].map(w => 10 * (mg(w) - ref));
  const env = R.agc[0].slice(2);
  let worst = 0; env.forEach((v, i) => { worst = Math.max(worst, Math.abs(v - want[i])); });
  check('level curve of the gain test follows the model', worst <= 40, 'worst ' + (worst / 10).toFixed(1) + ' dB; model ' + want.map(v => (v / 10).toFixed(0)).join(' ') + ' | read ' + env.map(v => (v / 10).toFixed(0)).join(' '));
  check('the fall is reported', R.agc[0][5] < -100, 'level at 0.5 s: ' + R.agc[0][5] / 10 + ' dB');
  check('the verdict names automatic gain', R.txt.some(l => /automatic gain\./.test(l)));
}

// ---- 3. nothing useful recorded ----
{
  const n = 43230 * 30, b = Buffer.alloc(2 * n); for (let j = 0; j < n; j++) b.writeInt16LE(Math.round(0.3 * gauss()), 2 * j);
  const f = path.join(process.env.TMPDIR || '/tmp', 'scan-empty.raw'); fs.writeFileSync(f, b);
  const txt = cp.execFileSync(path.join(__dirname, 'scansim'), [f, '44100']).toString();
  check('silence: reported as a failure with a reason', /^ok 0/m.test(txt) && /marker/.test(txt), (txt.match(/^err .*/m) || [''])[0]);
  const f2 = path.join(process.env.TMPDIR || '/tmp', 'scan-short.raw'); fs.writeFileSync(f2, b.subarray(0, 2 * 43230 * 10));
  const t2 = cp.execFileSync(path.join(__dirname, 'scansim'), [f2, '44100']).toString();
  check('too short a recording: reported', /^ok 0/m.test(t2) && /too short/.test(t2));
}

console.log(pass + ' of ' + tot + ' checks passed');
process.exit(pass === tot ? 0 : 1);
