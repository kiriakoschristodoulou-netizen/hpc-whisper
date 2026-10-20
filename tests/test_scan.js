// Mic Scan: the phone's test signal goes through a modelled handheld microphone (response, ghosts, automatic gain, noise,
// a rate that is not the claimed one); handheld/scanlib.pas must find back what the model did.
const P = require('../scanplan.js'), fs = require('fs'), cp = require('child_process'), path = require('path');
const REAL = 43230, CLAIM = 44100, FS = REAL;   // the signal is made straight at the microphone's real rate
let seed = 12345; const rnd = () => ((seed = (seed * 1664525 + 1013904223) >>> 0) / 4294967296);
const gauss = () => { let s = 0; for (let i = 0; i < 6; i++) s += rnd(); return (s - 3) * Math.SQRT2; };
let pass = 0, tot = 0;
const check = (name, ok, info) => { tot++; if (ok) pass++; console.log((ok ? 'ok    ' : 'FAIL  ') + name + (info ? '  ' + info : '')); };

// the microphone's response in dB: flat to 13.75 kHz, then a cliff of 35 dB falling on to -55 at 21.5 kHz
const H = hz => hz <= 13750 ? 0 : -35 - 20 * (hz - 14000) / 7500;
const GH = 0.3;                                   // ghost: 900 Hz below, 0.3 of the tone
const DC = 800;                                   // the microphone's offset, in counts

function run(name, agc) {
  const SC = 20000;
  const x = P.render(FS, hz => [[hz, SC * Math.pow(10, H(hz) / 20)], [hz - 900, GH * SC * Math.pow(10, H(hz) / 20)]]);
  // automatic gain (a compressor): the output is pulled toward 2500 counts; attack 20 ms, release 300 ms
  const y = new Float32Array(x.length); let g = 1, env = 0;
  const att = 1 - Math.exp(-1 / (0.02 * FS)), rel = 1 - Math.exp(-1 / (0.3 * FS)), dec = Math.exp(-1 / (0.03 * FS));
  for (let i = 0; i < x.length; i++) {
    if (agc) {
      const a = Math.abs(x[i]);
      env = a > env ? a : env * dec;
      const gt = Math.min(1, 2500 / Math.max(env, 1));
      g += (gt - g) * (gt < g ? att : rel);
    }
    y[i] = x[i] * g;
  }
  // the recording: 2.3 s before the phone starts, the signal, 4 s after; noise 0.3 counts; offset
  const pre = Math.round(2.3 * REAL), n = pre + y.length + 4 * REAL, out = Buffer.alloc(2 * n);
  for (let j = 0; j < n; j++) {
    let v = j >= pre && j - pre < y.length ? y[j - pre] : 0;
    v += DC + 0.3 * gauss();
    out.writeInt16LE(Math.max(-32768, Math.min(32767, Math.round(v))), 2 * j);
  }
  const f = path.join(process.env.TMPDIR || '/tmp', 'scan-' + name + '.raw'); fs.writeFileSync(f, out);
  const txt = cp.execFileSync(path.join(__dirname, 'scansim'), [f, String(CLAIM)]).toString().split('\n');
  const R = { tone: [], agc: [], burst: [[], []], lin: [] };
  for (const l of txt) {
    const w = l.split(' ');
    if (w[0] === 'ok') R.ok = +w[1]; else if (w[0] === 'err') R.err = l;
    else if (w[0] === 'rate100') R.rate = +w[1] / 100; else if (w[0] === 'mark') R.mark = [+w[1], +w[2]];
    else if (w[0] === 'noise') R.noise = +w[1]; else if (w[0] === 'dc') R.dc = +w[1];
    else if (w[0] === 'tone') R.tone[+w[1]] = w.slice(2).map(Number);
    else if (w[0] === 'agc') R.agc[+w[1]] = w.slice(2).map(Number);
    else if (w[0] === 'burst') R.burst[+w[1]][+w[2]] = [+w[3], +w[4]];
    else if (w[0] === 'lin') R.lin[+w[1]] = w.slice(2).map(Number);
    else if (w[0] === 'verdict') R.verdict = w.slice(1).map(Number);
    else if (w[0] === '#' && /Real sampling|response|Automatic|follows/.test(l)) console.log('      ' + l.slice(2));
  }
  R.txt = txt; return { R, SC };
}

// ---- 1. a steady microphone with an offset and a cliff ----
{
  const { R, SC } = run('flat', false);
  check('analysis ran', R.ok === 1, R.err || '');
  check('real rate found', Math.abs(R.rate - REAL) / REAL < 0.0005, R.rate + ' (model ' + REAL + ')');
  check('offset found', Math.abs(R.dc - DC) <= 3, R.dc + ' (model ' + DC + ')');
  let worst = 0, wi = 0;
  for (let i = 0; i < P.NTONE; i++) {
    const truth = 200 * Math.log10(P.TONE_AMP * SC * Math.pow(10, H(P.toneHz(i)) / 20) / 32768);
    const d = Math.abs(R.tone[i][0] - truth); if (d > worst) { worst = d; wi = i; }
  }
  check('all 52 tone levels within 1.5 dB', worst <= 15, 'worst ' + (worst / 10).toFixed(1) + ' dB at ' + P.toneHz(wi) + ' Hz');
  let gw = 0;
  for (let i = 4; i < P.NTONE; i++) { const d = Math.abs(R.tone[i][3] - 200 * Math.log10(GH)); if (R.tone[i][0] - R.tone[i][1] > 150 && d > gw) gw = d; }
  check('ghost 900 Hz below found at -10.5 dB', gw <= 20, 'worst deviation ' + (gw / 10).toFixed(1) + ' dB');
  check('no ghost above', R.tone[20][4] < -200, 'level ' + R.tone[20][4] / 10);
  let fall = 0; for (let i = 0; i < P.NTONE; i++) fall = Math.max(fall, Math.abs(R.tone[i][2]));
  check('steady microphone: no fall', fall <= 15, 'largest ' + fall / 10 + ' dB');
  check('noise floor near -98 dBFS with the offset removed', R.noise < -950 && R.noise > -1050, R.noise / 10 + ' dBFS');
  check('background at one frequency, measured like a tone (about -128 dBFS)', Math.abs(R.tone[10][1] - (-1280)) <= 40, R.tone[10][1] / 10 + ' dBFS');
  check('the cliff is found at 14 kHz', R.verdict[1] === 14000, 'cliff ' + R.verdict[1]);
  check('strong signal reaches the top (model: 21.5 kHz)', R.verdict[2] >= 21000, 'top ' + R.verdict[2]);
  check('the level follows the sound', R.verdict[4] === 1 && R.lin.every(l => l[0] >= 90 && l[0] <= 110), JSON.stringify(R.lin.map(l => l[0])));
  const compact = R.txt.filter(l => l.startsWith('$ ')).map(l => l.slice(2));
  check('the report for the phone is short (under 1,900 characters)', compact.join('\n').length < 1900, compact.join('\n').length + ' characters');
  check('bursts of 20 ms and more all seen', R.burst.every(s => s.slice(1).every(b => b[1] >= 5)), JSON.stringify(R.burst));
  check('burst level near the steady tone (>= -3 dB)', R.burst.every(s => s.slice(2).every(b => b[0] > -30)), JSON.stringify(R.burst.map(s => s.map(b => b[0] / 10))));
}

// ---- 2. a microphone with automatic gain ----
{
  const { R } = run('agc', true);
  check('analysis ran (AGC)', R.ok === 1, R.err || '');
  check('real rate found (AGC)', Math.abs(R.rate - REAL) / REAL < 0.0005, R.rate + '');
  check('the level does not follow the sound', R.verdict[4] === 0 && R.lin.slice(0, 2).every(l => l[0] < 40), JSON.stringify(R.lin.map(l => l[0])));
  check('the fall is reported (90 % at 12 kHz)', R.agc[0][2 + 6] < -100, 'level at 0.8 s: ' + R.agc[0][8] / 10 + ' dB');
  check('the verdict names automatic gain', R.txt.some(l => /^# Automatic gain/.test(l)));
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
