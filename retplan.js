/* Return Test signal: what the phone plays and the handheld measures (handheld/retlib.pas has the same plan).
   Blocks of 96 symbols, each symbol one of 16 tones 100 Hz apart, after a preamble tone. */
(function (root) {
  'use strict';
  const P = {
    MARK_HZ: 4000, MARK_MS: 600, MARK_AMP: 0.9, START: 2000, PRE_MS: 400, GAP_MS: 300, NSYM: 96,
    END_AT: 49500, PLAN_MS: 50100, NBLK: 12
  };
  const VOL = [90, 45, 22], SYM = [48, 32, 20], BASE_X = [16000, 17000, 19000];
  // block k: 0..8 = volume (90, 45, 22 %) x symbol length (48, 32, 20 ms) at 18.0-19.5 kHz; 9..11 = other bands at 90 %, 32 ms
  P.base = k => k < 9 ? 18000 : BASE_X[k - 9];
  P.amp = k => k < 9 ? VOL[Math.floor(k / 3)] : 90;
  P.sym = k => k < 9 ? SYM[k % 3] : 32;
  P.start = k => { let t = P.START; for (let i = 0; i < k; i++) t += P.PRE_MS + P.NSYM * P.sym(i) + P.GAP_MS; return t; };
  P.symbols = k => { const s = []; let x = 777 + k; for (let j = 0; j < P.NSYM; j++) { x = (Math.imul(x, 1103515245) + 12345) & 0x7fffffff; s.push((x >> 16) & 15); } return s; };

  // [startMs, lengthMs, hz, amplitude, rampMs]
  P.segments = function () {
    const s = [[0, P.MARK_MS, P.MARK_HZ, P.MARK_AMP, 5]];
    for (let k = 0; k < P.NBLK; k++) {
      const t = P.start(k), a = P.amp(k) / 100, sy = P.symbols(k), L = P.sym(k);
      s.push([t, P.PRE_MS, P.base(k) + 500, a, 5]);
      for (let j = 0; j < P.NSYM; j++) s.push([t + P.PRE_MS + j * L, L, P.base(k) + 100 * sy[j], a, 1.5]);
    }
    s.push([P.END_AT, P.MARK_MS, P.MARK_HZ, P.MARK_AMP, 5]);
    return s;
  };

  P.render = function (rate, shape) {
    const n = Math.ceil((P.PLAN_MS + 400) / 1000 * rate), x = new Float32Array(n);
    for (const [at, len, hz, amp, ramp] of P.segments()) {
      const a = Math.round(at / 1000 * rate), m = Math.round(len / 1000 * rate), f = Math.max(1, Math.round(ramp / 1000 * rate));
      const parts = shape ? shape(hz) : [[hz, 1]];
      for (let i = 0; i < m && a + i < n; i++) {
        const env = Math.min(1, (i + 1) / f, (m - i) / f);
        let v = 0;
        for (const [h, g] of parts) v += g * Math.sin(2 * Math.PI * h * (a + i) / rate);
        x[a + i] += amp * env * v;
      }
    }
    return x;
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = P; else root.RetPlan = P;
})(this);
