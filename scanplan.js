/* Mic Scan test signal: what the phone plays and the handheld measures (handheld/scanlib.pas has the same plan). */
(function (root) {
  'use strict';
  const P = {
    MARK_HZ: 4000, MARK_MS: 600, END_AT: 60000, PLAN_MS: 60600,
    NTONE: 43, TONE_HZ0: 500, TONE_STEP: 500, TONE_AT0: 2000, TONE_PERIOD: 600, TONE_MS: 450, TONE_AMP: 0.5,
    NAGC: 4, AGC_AT0: 28500, AGC_PERIOD: 6400, AGC_TONE_MS: 2000, AGC_GAP_MS: 1200,
    AGC_HZ: [3000, 19000, 3000, 19000], AGC_AMP: [0.9, 0.9, 0.22, 0.22],
    BURST_AT0: 54600, BURST_HZ: 19500, BURST_MS: [20, 40, 60, 100], BURST_N: 6, BURST_GAP: 150,
    MARK_AMP: 0.9
  };
  P.toneHz = i => P.TONE_HZ0 + i * P.TONE_STEP;

  // every piece of sound: [startMs, lengthMs, hz, amplitude]
  P.segments = function () {
    const s = [];
    s.push([0, P.MARK_MS, P.MARK_HZ, P.MARK_AMP]);
    for (let i = 0; i < P.NTONE; i++) s.push([P.TONE_AT0 + i * P.TONE_PERIOD, P.TONE_MS, P.toneHz(i), P.TONE_AMP]);
    for (let g = 0; g < P.NAGC; g++) {
      const t = P.AGC_AT0 + g * P.AGC_PERIOD;
      s.push([t, P.AGC_TONE_MS, P.AGC_HZ[g], P.AGC_AMP[g]]);
      s.push([t + P.AGC_TONE_MS + P.AGC_GAP_MS, P.AGC_TONE_MS, P.AGC_HZ[g], P.AGC_AMP[g]]);
    }
    let t = P.BURST_AT0;
    for (let g = 0; g < 4; g++) for (let k = 0; k < P.BURST_N; k++) { s.push([t, P.BURST_MS[g], P.BURST_HZ, P.TONE_AMP]); t += P.BURST_MS[g] + P.BURST_GAP; }
    s.push([P.END_AT, P.MARK_MS, P.MARK_HZ, P.MARK_AMP]);
    return s;
  };

  // the whole signal at a sample rate (5 ms fades in and out so there are no clicks). shape(hz) -> list of [hz, gain] partials (the test's microphone).
  P.render = function (rate, shape) {
    const n = Math.ceil((P.PLAN_MS + 400) / 1000 * rate), x = new Float32Array(n);
    for (const [at, len, hz, amp] of P.segments()) {
      const a = Math.round(at / 1000 * rate), m = Math.round(len / 1000 * rate), f = Math.max(1, Math.round(0.005 * rate));
      const parts = shape ? shape(hz) : [[hz, 1]];
      for (let i = 0; i < m && a + i < n; i++) {
        const env = Math.min(1, i / f, (m - 1 - i) / f);
        let v = 0;
        for (const [h, g] of parts) v += g * Math.sin(2 * Math.PI * h * (a + i) / rate);
        x[a + i] += amp * env * v;
      }
    }
    return x;
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = P; else root.ScanPlan = P;
})(this);
