/* Mic Scan test signal: what the phone plays and the handheld measures (handheld/scanlib.pas has the same plan). */
(function (root) {
  'use strict';
  const P = {
    MARK_HZ: 4000, MARK_MS: 600, END_AT: 80000, PLAN_MS: 80600, MARK_AMP: 0.9,
    NTONE: 52, TONE_AT0: 3000, TONE_PERIOD: 500, TONE_MS: 400, TONE_AMP: 0.5,
    NLINF: 3, NLINA: 5, LIN_AT0: 29500, LIN_PERIOD: 1000, LIN_MS: 600,
    LIN_HZ: [3000, 12000, 19000], LIN_AMP: [0.90, 0.45, 0.22, 0.11, 0.06],
    SET_AT: 75500, SET_MS: 4000, SET_HZ: 18500, SET_AMP: 0.5,
    NAGC: 4, AGC_AT0: 45000, AGC_PERIOD: 5000, AGC_TONE_MS: 1500, AGC_GAP_MS: 1000,
    AGC_HZ: [12000, 12000, 19000, 19000], AGC_AMP: [0.9, 0.22, 0.9, 0.22],
    BURST_AT: [65500, 70500], BURST_HZ: [12500, 19500], BURST_MS: [10, 20, 40, 100], BURST_N: 6, BURST_GAP: 150
  };
  // 0.5 to 9.5 kHz every 500 Hz, 10 to 14.5 every 250 Hz, 15 to 21.5 every 500 Hz
  P.toneHz = i => i < 19 ? 500 * (i + 1) : i < 38 ? 10000 + (i - 19) * 250 : 15000 + (i - 38) * 500;

  // every piece of sound: [startMs, lengthMs, hz, amplitude]
  P.segments = function () {
    const s = [];
    s.push([0, P.MARK_MS, P.MARK_HZ, P.MARK_AMP]);
    for (let i = 0; i < P.NTONE; i++) s.push([P.TONE_AT0 + i * P.TONE_PERIOD, P.TONE_MS, P.toneHz(i), P.TONE_AMP]);
    for (let f = 0; f < P.NLINF; f++) for (let g = 0; g < P.NLINA; g++)
      s.push([P.LIN_AT0 + (f * P.NLINA + g) * P.LIN_PERIOD, P.LIN_MS, P.LIN_HZ[f], P.LIN_AMP[g]]);
    for (let g = 0; g < P.NAGC; g++) {
      const t = P.AGC_AT0 + g * P.AGC_PERIOD;
      s.push([t, P.AGC_TONE_MS, P.AGC_HZ[g], P.AGC_AMP[g]]);
      s.push([t + P.AGC_TONE_MS + P.AGC_GAP_MS, P.AGC_TONE_MS, P.AGC_HZ[g], P.AGC_AMP[g]]);
    }
    for (let sm = 0; sm < 2; sm++) {
      let t = P.BURST_AT[sm];
      for (let g = 0; g < 4; g++) for (let k = 0; k < P.BURST_N; k++) { s.push([t, P.BURST_MS[g], P.BURST_HZ[sm], P.TONE_AMP]); t += P.BURST_MS[g] + P.BURST_GAP; }
    }
    s.push([P.SET_AT, P.SET_MS, P.SET_HZ, P.SET_AMP]);
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
