/* J720 Whisper sound format, shared by the receiver page and the tests.

   Tones: a grid of 100 Hz steps from 18.0 to 21.5 kHz. A band is 16 neighbouring
   grid tones (1.5 kHz wide) starting at 18.0, 18.5, 19.0, 19.5 or 20.0 kHz.
   Each symbol is one tone = 4 bits. Speeds: 48, 32 or 20 ms per symbol.

   Frame: preamble (6 symbols) then the data in blocks of 15 symbols, each a
   Reed-Solomon (15,11) code word over GF(16): 11 data nibbles + 4 check nibbles,
   so up to 2 wrong symbols per block are corrected.
   Data bytes: [length, sequence, text bytes (UTF-8) ..., CRC-16 (2 bytes)], high nibble first.
   The receiver tries every band and speed at once, so the sender's settings need
   no matching on the phone. */
(function (root) {
  'use strict';

  const GRID_START = 18000, GRID_STEP = 100, GRID_N = 36;          // 18.0 .. 21.5 kHz
  const BANDS = [18000, 18500, 19000, 19500, 20000];                // band starts
  const SPEEDS = [0.048, 0.032, 0.020];                             // seconds per symbol
  const PREAMBLE = [0, 15, 0, 15, 4, 11];
  const MAXLEN = 48;                                                // text bytes per frame

  // ---------- GF(16), x^4 + x + 1 ----------
  const EXP = new Array(30), LOG = new Array(16);
  (function () {
    let x = 1;
    for (let i = 0; i < 15; i++) { EXP[i] = x; LOG[x] = i; x <<= 1; if (x & 16) x ^= 0x13; }
    for (let i = 15; i < 30; i++) EXP[i] = EXP[i - 15];
  })();
  const mul = (a, b) => (a && b) ? EXP[LOG[a] + LOG[b]] : 0;
  const div = (a, b) => a ? EXP[(LOG[a] - LOG[b] + 15) % 15] : 0;
  // generator (x - a^1)(x - a^2)(x - a^3)(x - a^4), highest power first
  const GEN = (function () {
    let g = [1];
    for (let i = 1; i <= 4; i++) {
      const r = new Array(g.length + 1).fill(0);
      for (let j = 0; j < g.length; j++) { r[j] ^= g[j]; r[j + 1] ^= mul(g[j], EXP[i]); }
      g = r;
    }
    return g;
  })();

  function rsEncode(data11) {                 // 11 nibbles -> 15 (data then 4 checks)
    const r = data11.concat([0, 0, 0, 0]);
    for (let i = 0; i < 11; i++) {
      const c = r[i];
      if (c) for (let j = 1; j < 5; j++) r[i + j] ^= mul(GEN[j], c);
    }
    return data11.concat(r.slice(11));
  }

  // value of the polynomial c (c[0] = highest power, degree 14) at x
  function polyAt(c, x) { let y = 0; for (let i = 0; i < c.length; i++) y = mul(y, x) ^ c[i]; return y; }

  function rsDecode(word15) {                 // -> {data: 11 nibbles, fixed: n} or null
    const c = word15.slice();
    const S = [];
    let bad = false;
    for (let i = 1; i <= 4; i++) { S[i] = polyAt(c, EXP[i]); if (S[i]) bad = true; }
    if (!bad) return { data: c.slice(0, 11), fixed: 0 };
    // Berlekamp-Massey: error locator L (L[0] = 1, low power first)
    let L = [1], B = [1], len = 0, m = 1, b = 1;
    for (let n = 0; n < 4; n++) {
      let d = S[n + 1];
      for (let i = 1; i <= len; i++) d ^= mul(L[i] || 0, S[n + 1 - i]);
      if (d === 0) { m++; continue; }
      const T = L.slice();
      const coef = div(d, b);
      const need = B.length + m;
      while (L.length < need) L.push(0);
      for (let i = 0; i < B.length; i++) L[i + m] ^= mul(coef, B[i]);
      if (2 * len <= n) { len = n + 1 - len; B = T; b = d; m = 1; } else m++;
    }
    if (len > 2) return null;
    // Chien search: positions p (power of x, 0..14) where L(a^-p) = 0
    const pos = [];
    for (let p = 0; p < 15; p++) {
      const xi = EXP[(15 - p) % 15];
      let v = 0;
      for (let i = L.length - 1; i >= 0; i--) v = mul(v, xi) ^ (L[i] || 0);
      if (v === 0) pos.push(p);
    }
    if (pos.length !== len) return null;
    // Forney: Omega = S(x) L(x) mod x^4, with S(x) = S1 + S2 x + ...
    const Om = [0, 0, 0, 0];
    for (let i = 0; i < 4; i++) for (let j = 0; j <= i; j++) Om[i] ^= mul(S[i - j + 1], L[j] || 0);
    for (const p of pos) {
      const xi = EXP[(15 - p) % 15];
      let om = 0; for (let i = 3; i >= 0; i--) om = mul(om, xi) ^ Om[i];
      let dl = 0;                              // formal derivative: the odd terms
      for (let i = 1; i < L.length; i += 2) if (L[i]) dl ^= mul(L[i], EXP[(LOG[xi] * (i - 1)) % 15]);
      if (!dl) return null;
      const e = div(om, dl);
      c[14 - p] ^= e;
    }
    for (let i = 1; i <= 4; i++) if (polyAt(c, EXP[i])) return null;
    return { data: c.slice(0, 11), fixed: pos.length };
  }

  function crc16(bytes) {                     // CCITT, start 0xFFFF
    let c = 0xFFFF;
    for (const v of bytes) { c ^= v << 8; for (let k = 0; k < 8; k++) c = (c & 0x8000) ? ((c << 1) ^ 0x1021) & 0xFFFF : (c << 1) & 0xFFFF; }
    return c;
  }

  function blocksFor(len) { return Math.ceil((len + 4) * 2 / 11); }

  // text bytes -> symbol values 0..15 (preamble included)
  function encodeFrame(textBytes, seq) {
    const by = [textBytes.length, seq & 255].concat(Array.from(textBytes));
    const c = crc16(by); by.push(c >> 8, c & 255);
    const nib = [];
    for (const v of by) { nib.push(v >> 4, v & 15); }
    const nb = blocksFor(textBytes.length);
    while (nib.length < nb * 11) nib.push(0);
    let sym = PREAMBLE.slice();
    for (let k = 0; k < nb; k++) sym = sym.concat(rsEncode(nib.slice(k * 11, k * 11 + 11)));
    return sym;
  }

  // test signal: symbols -> samples (phase-continuous tones, soft ends)
  function synth(symbols, rate, band, speed, amp) {
    const n0 = Math.round(rate * 0.02);
    const total = Math.round(symbols.length * speed * rate) + 2 * n0;
    const out = new Float32Array(total);
    let ph = 0;
    const fade = Math.round(rate * 0.005);
    const nSym = Math.round(symbols.length * speed * rate);
    for (let i = 0; i < nSym; i++) {
      const k = Math.min(symbols.length - 1, Math.floor(i / (speed * rate)));
      const f = band + symbols[k] * GRID_STEP;
      ph += 2 * Math.PI * f / rate;
      let e = 1;
      if (i < fade) e = i / fade; else if (i > nSym - fade) e = (nSym - i) / fade;
      out[n0 + i] = amp * e * Math.sin(ph);
    }
    return out;
  }

  // ---------- the receiver ----------
  // Feed samples in any chunk size; calls onFrame({text, band, speed, fixed}) and onBad(info).
  class Receiver {
    constructor(rate, opts) {
      opts = opts || {};
      this.rate = rate;
      this.blk = Math.round(rate / 1000);                 // 1 ms blocks
      this.onFrame = opts.onFrame || (() => {});
      this.onBad = opts.onBad || (() => {});
      this.cap = 12000;                                   // blocks kept (12 s: longer than the longest frame)
      // per grid tone: prefix sums of the complex block values (re, im)
      this.pre = [];
      for (let t = 0; t < GRID_N; t++) this.pre.push({ re: new Float64Array(this.cap + 1), im: new Float64Array(this.cap + 1) });
      this.n = 0;                                         // blocks done (absolute)
      this.sampleCount = 0;                               // absolute sample index
      this.acc = new Float64Array(GRID_N * 2);
      this.inBlk = 0;
      this.w = []; for (let t = 0; t < GRID_N; t++) this.w.push(2 * Math.PI * (GRID_START + t * GRID_STEP) / rate);
      // fast oscillators: cos/sin tables per tone would be big; use recurrence per block
      this.cosw = this.w.map(Math.cos); this.sinw = this.w.map(Math.sin);
      this.osc = []; for (let t = 0; t < GRID_N; t++) this.osc.push({ c: 1, s: 0 });
      this.lock = null;                                   // frame being read
      this.cand = null;                                   // best preamble seen lately
      this.skipUntil = 0;
      this.level = 0; this.noise = 1e-9;
      this.stats = { frames: 0, bad: 0, fixed: 0 };
    }

    push(samples) {
      const B = this.blk;
      for (let i = 0; i < samples.length; i++) {
        const x = samples[i];
        for (let t = 0; t < GRID_N; t++) {
          const o = this.osc[t];
          this.acc[2 * t] += x * o.c; this.acc[2 * t + 1] -= x * o.s;
          const c = o.c * this.cosw[t] - o.s * this.sinw[t];
          o.s = o.s * this.cosw[t] + o.c * this.sinw[t]; o.c = c;
        }
        if (++this.inBlk === B) { this.endBlock(); this.inBlk = 0; }
      }
    }

    endBlock() {
      // keep the oscillators exact (amplitude 1)
      if ((this.n & 63) === 0) for (const o of this.osc) { const r = Math.hypot(o.c, o.s); o.c /= r; o.s /= r; }
      const k = this.n % this.cap, k1 = (this.n + 1) % this.cap;
      let p = 0;
      for (let t = 0; t < GRID_N; t++) {
        const P = this.pre[t];
        // prefix stored in a ring: value at slot k1 = value at k + this block
        P.re[k1] = P.re[k] + this.acc[2 * t];
        P.im[k1] = P.im[k] + this.acc[2 * t + 1];
        p += this.acc[2 * t] ** 2 + this.acc[2 * t + 1] ** 2;
        this.acc[2 * t] = 0; this.acc[2 * t + 1] = 0;
      }
      this.n++;
      this.level = 0.98 * this.level + 0.02 * p;
      this.step();
    }

    // power of grid tone t over absolute blocks [a, b)
    pow(t, a, b) {
      const P = this.pre[t], A = a % this.cap, Bk = b % this.cap;
      const re = P.re[Bk] - P.re[A], im = P.im[Bk] - P.im[A];
      return re * re + im * im;
    }

    // which of the 16 tones of a band is strongest in symbol window [a, b); also its share
    sym(band, a, b) {
      let best = -1, bv = -1, sum = 0;
      for (let i = 0; i < 16; i++) {
        const v = this.pow(band + i, a, b);
        sum += v;
        if (v > bv) { bv = v; best = i; }
      }
      return { s: best, share: sum > 0 ? bv / sum : 0, p: bv };
    }

    // the part of symbol k used for the decision: skip the start (echo of the previous one)
    win(start, D, k) {
      const a = start + Math.round(k * D + D * 0.25), b = start + Math.round(k * D + D * 0.9);
      return [a, Math.max(b, a + 1)];
    }

    step() {
      const now = this.n;
      if (this.lock) { this.readLock(); return; }
      if (now < this.skipUntil) return;
      // a preamble that ended just now, for every band and speed
      let best = null;
      for (let bi = 0; bi < BANDS.length; bi++) {
        const band = (BANDS[bi] - GRID_START) / GRID_STEP;
        for (let si = 0; si < SPEEDS.length; si++) {
          const D = SPEEDS[si] * 1000;                    // blocks per symbol
          const start = now - Math.round(PREAMBLE.length * D);
          if (start < 1 || now - start > this.cap - 10) continue;
          let minShare = 1, sumShare = 0;
          let ok = true;
          for (let k = 0; k < PREAMBLE.length; k++) {
            const [a, b] = this.win(start, D, k);
            const r = this.sym(band, a, b);
            if (r.s !== PREAMBLE[k]) { ok = false; break; }
            minShare = Math.min(minShare, r.share);
            sumShare += r.share;
          }
          if (!ok || minShare < 0.3 || sumShare < 0.45 * PREAMBLE.length) continue;
          const score = sumShare;
          if (!best || score > best.score) best = { score, band, bandHz: BANDS[bi], si, D, start };
        }
      }
      if (best) {
        if (!this.cand || best.score >= this.cand.score) this.cand = best;
        this.candAge = 0;
      } else if (this.cand) {
        // the best moment has passed: lock on to it
        if (++this.candAge > 2) { this.startLock(this.cand); this.cand = null; }
      }
    }

    startLock(c) {
      let ref = 0;
      for (let k = 0; k < PREAMBLE.length; k++) { const [a, b] = this.win(c.start, c.D, k); ref += this.sym(c.band, a, b).p / (b - a); }
      ref /= PREAMBLE.length;
      this.lock = { ref, band: c.band, bandHz: c.bandHz, si: c.si, D: c.D, start: c.start + Math.round(PREAMBLE.length * c.D), nblk: 0, score: c.score, off: 0 };
    }

    // symbol k of the frame being read; from symbol p on, o blocks later (a gap)
    symAt(k, p, o) {
      const L = this.lock;
      const [a, b] = this.win(L.start + (k >= p ? o : 0), L.D, k);
      return this.sym(L.band, a, b).s;
    }

    // the whole frame read with a gap of o blocks before symbol p; null if it does not check out
    searchGap(from, to, maxO, nblkKnown) {
      let best = null;
      for (let p = from; p < to; p++) {
        for (let o = 1; o <= maxO; o++) {
          const t = this.decodeWith(p, o, nblkKnown);
          if (t.by && (!best || t.fixed < best.fixed)) { best = t; best.o = o; }
        }
        if (best && best.fixed === 0) break;
      }
      if (best) { this.lock.off = best.o; this.stats.gaps = (this.stats.gaps || 0) + 1; }
      return best;
    }

    decodeWith(p, o, nblkKnown) {
      const nib = []; let fixed = 0, nblk = nblkKnown || 1, firstFix = -1;
      for (let j = 0; j < nblk; j++) {
        const w = []; for (let i = 0; i < 15; i++) w.push(this.symAt(j * 15 + i, p, o));
        const r = rsDecode(w);
        if (!r) return { bad: firstFix >= 0 ? firstFix : j };
        if (r.fixed && firstFix < 0) firstFix = j;
        fixed += r.fixed; nib.push(...r.data);
        if (j === 0) {
          const len = (r.data[0] << 4) | r.data[1];
          if (len > MAXLEN) return { bad: 0 };
          if (nblkKnown && blocksFor(len) !== nblkKnown) return { bad: 0 };
          nblk = blocksFor(len);
        }
      }
      const by = [];
      for (let i = 0; i + 1 < nib.length; i += 2) by.push((nib[i] << 4) | nib[i + 1]);
      const len = by[0];
      // a wrong reading can pass a block's own check, so the first block that
      // needed correcting is the likeliest place where things went wrong
      if (crc16(by.slice(0, len + 2)) !== ((by[len + 2] << 8) | by[len + 3])) return { bad: firstFix >= 0 ? firstFix : nblk - 1, crc: true };
      return { by, len, fixed, nblk };
    }

    readLock() {
      const L = this.lock;
      const maxO = Math.max(Math.round(L.D * 2.5), 80);
      // how long the frame is: from the first block, read as it comes
      if (L.nblk === 0) {
        const [, e0] = this.win(L.start, L.D, 14);
        if (e0 > this.n) return;
        const w = []; for (let i = 0; i < 15; i++) w.push(this.symAt(i, 1e9, 0));
        const r = rsDecode(w), len = r ? (r.data[0] << 4) | r.data[1] : 999;
        L.nblk = len <= MAXLEN ? blocksFor(len) : -1;    // -1: unknown, try each length in turn
        L.tryN = 1;
      }
      let res = null;
      if (L.nblk > 0) {
        const [, end] = this.win(L.start, L.D, L.nblk * 15 - 1);
        if (end > this.n) return;
        res = this.decodeWith(1e9, 0);
        if (!res.by) {
          // the sender's sound may have stopped for a moment, which delays all
          // the tones after it: try each place and length of such a gap around
          // where the reading went wrong, and keep one that checks out
          if (end + maxO + 2 > this.n) return;            // wait for the delayed end too
          const best = this.searchGap(Math.max(0, (res.bad - 1) * 15), Math.min(L.nblk * 15, (res.bad + 1) * 15), maxO, 0);
          if (!best) { this.fail(res.crc ? 'check' : 'block ' + (res.bad + 1)); return; }
          res = best;
        }
      } else {
        // the first block itself did not read: a gap early on. Try the
        // possible lengths, shortest first, as soon as each could be complete
        while (true) {
          const [, end] = this.win(L.start, L.D, L.tryN * 15 - 1);
          if (end + maxO + 2 > this.n) return;
          res = this.searchGap(0, 30, maxO, L.tryN);
          if (res) break;
          if (++L.tryN > blocksFor(MAXLEN)) { this.fail('first block'); return; }
        }
      }
      const by = res.by, len = res.len, fixed = res.fixed;
      this.stats.frames++; this.stats.fixed += fixed;
      const end2 = L.start + L.off + Math.round(res.nblk * 15 * L.D);
      this.skipUntil = end2 + 5;
      this.lock = null;
      this.onFrame({ bytes: by.slice(2, 2 + len), seq: by[1], bandHz: L.bandHz, ms: Math.round(SPEEDS[L.si] * 1000), fixed, gap: L.off });
    }

    fail(why) {
      this.stats.bad++;
      const L = this.lock;
      this.lock = null;
      this.skipUntil = this.n + 5;
      this.onBad({ why, bandHz: L.bandHz, ms: Math.round(SPEEDS[L.si] * 1000) });
    }
  }

  const api = { GRID_START, GRID_STEP, BANDS, SPEEDS, PREAMBLE, MAXLEN, rsEncode, rsDecode, crc16, encodeFrame, synth, Receiver, blocksFor };
  if (typeof module !== 'undefined' && module.exports) module.exports = api; else root.Whisper = api;
})(this);
