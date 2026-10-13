/* HPC Whisper sound format, version 2. Shared by the receiver page and the
   tests; the Android keyboard has a line-by-line Java port (Receiver.java).

   Tones: a grid of 100 Hz steps from 18.0 to 21.5 kHz. A band is 16
   neighbouring grid tones starting at 18.0, 18.5, 19.0, 19.5 or 20.0 kHz.
   Each symbol is one tone = 4 bits. Speeds: 48, 32 or 20 ms per symbol.

   A frame carries a piece of the handheld's document:
     preamble   8 symbols  0 15 0 15 11 4 11 4 (found even with two of them drowned out)
     header     1 block    version, text length n, sequence, document id, document length L
     body       B blocks   offset o, n text bytes, CRC-16 (of every byte above)
   A block is a Reed-Solomon (15,11) code word over GF(16). All B + 1 blocks
   are interleaved (symbol t after the preamble belongs to block t mod (B+1),
   the header being block 0), so a burst of noise or a dropout is spread
   thinly over every block. The receiver tries each possible B.

   The receiver keeps a mirror of the document: each frame says "the document
   is L bytes long and from o it reads ...". The handheld sends new text at
   once and repeats it during pauses, so a lost frame only leaves a gap that
   fills in a moment later. See docs/FORMAT.md. */
(function (root) {
  'use strict';

  const GRID_START = 18000, GRID_STEP = 100, GRID_N = 36;
  const BANDS = [18000, 18500, 19000, 19500, 20000];
  const SPEEDS = [0.048, 0.032, 0.020];
  const PREAMBLE = [0, 15, 0, 15, 11, 4, 11, 4];
  const VERSION = 2;
  const MAXLEN = 44;

  // ---------- GF(16), x^4 + x + 1 ----------
  const EXP = new Array(30), LOG = new Array(16);
  (function () {
    let x = 1;
    for (let i = 0; i < 15; i++) { EXP[i] = x; LOG[x] = i; x <<= 1; if (x & 16) x ^= 0x13; }
    for (let i = 15; i < 30; i++) EXP[i] = EXP[i - 15];
  })();
  const mul = (a, b) => (a && b) ? EXP[LOG[a] + LOG[b]] : 0;
  const div = (a, b) => a ? EXP[(LOG[a] - LOG[b] + 15) % 15] : 0;
  const GEN = (function () {
    let g = [1];
    for (let i = 1; i <= 4; i++) {
      const r = new Array(g.length + 1).fill(0);
      for (let j = 0; j < g.length; j++) { r[j] ^= g[j]; r[j + 1] ^= mul(g[j], EXP[i]); }
      g = r;
    }
    return g;
  })();

  function rsEncode(d) {
    const r = d.concat([0, 0, 0, 0]);
    for (let i = 0; i < 11; i++) {
      const c = r[i];
      if (c) for (let j = 1; j < 5; j++) r[i + j] ^= mul(GEN[j], c);
    }
    return d.concat(r.slice(11));
  }

  function polyAt(c, x) { let y = 0; for (let i = 0; i < c.length; i++) y = mul(y, x) ^ c[i]; return y; }

  // errors and erasures: 2 * errors + erasures <= 4. eras: indices 0..14 of symbols not to trust.
  function rsDecode(word, eras) {
    const c = word.slice();
    eras = eras || [];
    const S = [0];
    let bad = false;
    for (let i = 1; i <= 4; i++) { S[i] = polyAt(c, EXP[i]); if (S[i]) bad = true; }
    if (!bad) return { data: c.slice(0, 11), fixed: 0 };
    const f = eras.length;
    if (f > 4) return null;
    // erasure locator: product of (1 - X x), X = a^power, power = 14 - index
    let lam = [1];
    for (const idx of eras) {
      const X = EXP[14 - idx], n = new Array(lam.length + 1).fill(0);
      for (let j = 0; j < lam.length; j++) { n[j] ^= lam[j]; n[j + 1] ^= mul(lam[j], X); }
      lam = n;
    }
    let B = lam.slice(), L = f;
    for (let r = f + 1; r <= 4; r++) {
      let d = 0;
      for (let j = 0; j < lam.length && j < r; j++) d ^= mul(lam[j], S[r - j]);
      const xB = [0].concat(B);
      if (d === 0) { B = xB; continue; }
      const T = lam.slice();
      while (T.length < xB.length) T.push(0);
      for (let j = 0; j < xB.length; j++) T[j] ^= mul(d, xB[j]);
      if (2 * L <= r + f - 1) { L = r + f - L; B = lam.map(v => div(v, d)); }
      else B = xB;
      lam = T;
    }
    while (lam.length > 1 && lam[lam.length - 1] === 0) lam.pop();
    const deg = lam.length - 1;
    if (deg > 4 || 2 * (deg - f) + f > 4) return null;
    const pos = [];
    for (let p = 0; p < 15; p++) {
      const xi = EXP[(15 - p) % 15];
      let v = 0;
      for (let i = lam.length - 1; i >= 0; i--) v = mul(v, xi) ^ lam[i];
      if (v === 0) pos.push(p);
    }
    if (pos.length !== deg) return null;
    const Om = [0, 0, 0, 0];
    for (let i = 0; i < 4; i++) for (let j = 0; j <= i; j++) Om[i] ^= mul(S[i - j + 1], lam[j] || 0);
    for (const p of pos) {
      const xi = EXP[(15 - p) % 15];
      let om = 0; for (let i = 3; i >= 0; i--) om = mul(om, xi) ^ Om[i];
      let dl = 0;
      for (let i = 1; i < lam.length; i += 2) if (lam[i]) dl ^= mul(lam[i], EXP[(LOG[xi] * (i - 1)) % 15]);
      if (!dl) return null;
      c[14 - p] ^= div(om, dl);
    }
    for (let i = 1; i <= 4; i++) if (polyAt(c, EXP[i])) return null;
    return { data: c.slice(0, 11), fixed: pos.length };
  }

  function crc16(bytes) {
    let c = 0xFFFF;
    for (const v of bytes) { c ^= v << 8; for (let k = 0; k < 8; k++) c = (c & 0x8000) ? ((c << 1) ^ 0x1021) & 0xFFFF : (c << 1) & 0xFFFF; }
    return c;
  }

  function bodyBlocks(n) { return Math.ceil((n + 4) * 2 / 11); }

  function nibbles(bytes) { const r = []; for (const v of bytes) r.push(v >> 4, v & 15); return r; }

  // f = {n implied by bytes, seq, doc, L, o, bytes} -> symbols (preamble included)
  function encodeFrame(f) {
    const n = f.bytes.length;
    const head = [VERSION, n >> 4, n & 15, (f.seq >> 4) & 15, f.seq & 15, (f.doc >> 4) & 15, f.doc & 15,
      (f.L >> 12) & 15, (f.L >> 8) & 15, (f.L >> 4) & 15, f.L & 15];
    const all = [n, f.seq & 255, f.doc & 255, (f.L >> 8) & 255, f.L & 255, (f.o >> 8) & 255, f.o & 255].concat(Array.from(f.bytes));
    const crc = crc16(all);
    const body = nibbles([(f.o >> 8) & 255, f.o & 255].concat(Array.from(f.bytes), [crc >> 8, crc & 255]));
    const B = bodyBlocks(n);
    while (body.length < B * 11) body.push(0);
    const words = [];
    for (let k = 0; k < B; k++) words.push(rsEncode(body.slice(k * 11, k * 11 + 11)));
    words.unshift(rsEncode(head));
    const sym = PREAMBLE.slice(), K = B + 1;
    for (let t = 0; t < K * 15; t++) sym.push(words[t % K][Math.floor(t / K)]);
    return sym;
  }

  // test signal: symbols -> samples (phase-continuous tones, soft ends)
  function synth(symbols, rate, band, speed, amp) {
    const n0 = Math.round(rate * 0.02);
    const nSym = Math.round(symbols.length * speed * rate);
    const out = new Float32Array(nSym + 2 * n0);
    let ph = 0;
    const fade = Math.round(rate * 0.005);
    for (let i = 0; i < nSym; i++) {
      const k = Math.min(symbols.length - 1, Math.floor(i / (speed * rate)));
      ph += 2 * Math.PI * (band + symbols[k] * GRID_STEP) / rate;
      let e = 1;
      if (i < fade) e = i / fade; else if (i > nSym - fade) e = (nSym - i) / fade;
      out[n0 + i] = amp * e * Math.sin(ph);
    }
    return out;
  }

  // ---------- the receiver ----------
  class Receiver {
    constructor(rate, opts) {
      opts = opts || {};
      this.rate = rate;
      this.blk = Math.round(rate / 1000);                 // 1 ms blocks
      this.onFrame = opts.onFrame || (() => {});
      this.onBad = opts.onBad || (() => {});
      this.cap = 12000;                                   // blocks kept (12 s)
      this.pre = [];
      for (let t = 0; t < GRID_N; t++) this.pre.push({ re: new Float64Array(this.cap + 1), im: new Float64Array(this.cap + 1) });
      this.n = 0;
      this.acc = new Float64Array(GRID_N * 2);
      this.inBlk = 0;
      const w = []; for (let t = 0; t < GRID_N; t++) w.push(2 * Math.PI * (GRID_START + t * GRID_STEP) / rate);
      this.cosw = w.map(Math.cos); this.sinw = w.map(Math.sin);
      this.oc = new Float64Array(GRID_N).fill(1); this.os = new Float64Array(GRID_N);
      this.cands = new Map();                             // best preamble per band+speed, not yet final
      this.pending = [];                                  // preambles found, frames to read
      this.stats = { frames: 0, bad: 0, fixed: 0, gaps: 0, erased: 0 };
    }

    push(samples) {
      const B = this.blk, oc = this.oc, os = this.os, cw = this.cosw, sw = this.sinw, acc = this.acc;
      for (let i = 0; i < samples.length; i++) {
        const x = samples[i];
        for (let t = 0; t < GRID_N; t++) {
          const c = oc[t], s = os[t];
          acc[2 * t] += x * c; acc[2 * t + 1] -= x * s;
          oc[t] = c * cw[t] - s * sw[t];
          os[t] = s * cw[t] + c * sw[t];
        }
        if (++this.inBlk === B) { this.endBlock(); this.inBlk = 0; }
      }
    }

    endBlock() {
      if ((this.n & 63) === 0) for (let t = 0; t < GRID_N; t++) { const r = Math.hypot(this.oc[t], this.os[t]); this.oc[t] /= r; this.os[t] /= r; }
      const k = this.n % this.cap, k1 = (this.n + 1) % this.cap;
      for (let t = 0; t < GRID_N; t++) {
        const P = this.pre[t];
        P.re[k1] = P.re[k] + this.acc[2 * t];
        P.im[k1] = P.im[k] + this.acc[2 * t + 1];
        this.acc[2 * t] = 0; this.acc[2 * t + 1] = 0;
      }
      this.n++;
      this.search();
      this.readPending();
    }

    pow(t, a, b) {
      const P = this.pre[t], A = a % this.cap, Bk = b % this.cap;
      const re = P.re[Bk] - P.re[A], im = P.im[Bk] - P.im[A];
      return re * re + im * im;
    }

    // strongest of a band's 16 tones in [a, b); share = its part of the band's power
    sym(band, a, b) {
      let best = -1, bv = -1, sum = 0;
      for (let i = 0; i < 16; i++) {
        const v = this.pow(band + i, a, b);
        sum += v;
        if (v > bv) { bv = v; best = i; }
      }
      return { s: best, share: sum > 0 ? bv / sum : 0, p: bv };
    }

    // is tone want the strongest of the band, or a close second? share: its part of the band's power
    ranked(band, a, b, want) {
      let best = -1, second = -1, sum = 0;
      const v = new Array(16);
      for (let i = 0; i < 16; i++) { v[i] = this.pow(band + i, a, b); sum += v[i]; }
      for (let i = 0; i < 16; i++) { if (best < 0 || v[i] > v[best]) { second = best; best = i; } else if (second < 0 || v[i] > v[second]) second = i; }
      const share = sum > 0 ? v[want] / sum : 0;
      const ok = (want === best && share >= 0.3) || (want === second && v[want] >= 0.2 * v[best] && (v[want] + v[best]) / sum >= 0.6);
      return { ok, share: ok ? Math.max(share, 0.5) : 0 };
    }

    /* Some handhelds' sound chips add a "ghost" of every tone at a fixed distance
       (the Jornada 720: 900 Hz lower, sometimes louder than the tone itself).
       The preamble's tones are known, so measure the ghosts there: for each
       distance d (in grid steps), how strong is the sound d steps away from the
       tone, typically. Distances that are just the step between neighbouring
       preamble tones are left out (that could be echo of the previous one). */
    learnGhosts(F) {
      const skip = new Set([0, 1, -1, 2, -2, 15, -15, 4, -4, 7, -7, 11, -11]);
      const found = [];
      for (let d = -35; d <= 35; d++) {
        if (skip.has(d)) continue;
        const byTone = {}, all = [];
        for (let k = 0; k < PREAMBLE.length; k++) {
          const v = PREAMBLE[k], g = F.band + v, t = g + d;
          if (t < 0 || t >= GRID_N) continue;
          const [a, b] = this.win(F.pstart, F.D, k);
          const pg = this.pow(g, a, b);
          if (!(pg > 0)) continue;
          const r = this.pow(t, a, b) / pg;
          (byTone[v] = byTone[v] || []).push(r);
          all.push(r);
        }
        if (all.length < 3) continue;
        all.sort((x, y) => x - y);
        found.push({ d, med: all[all.length >> 1], low: all[(all.length - 1) >> 2], byTone });
      }
      if (!found.length) { F.ghosts = []; return; }
      const meds = found.map(x => x.med).sort((x, y) => x - y);
      const floor = meds[meds.length >> 1];
      // a ghost is there every time (even its weakest showing stands out) and is clearly
      // stronger than the background; weak ones do no harm, so at most the three strongest
      const keep = found.filter(x => x.med >= Math.max(0.05, 8 * floor) && x.low >= Math.max(0.02, 3 * floor))
                        .sort((x, y) => y.med - x.med).slice(0, 3);
      // a ghost's strength changes along the band (the speaker is weaker at the top):
      // measured at the preamble's tones, filled in between
      F.ghosts = keep.map(x => {
        const pts = Object.keys(x.byTone).map(Number).sort((p, q) => p - q)
          .map(v => [v, Math.log(Math.max(1e-3, Math.min(8, x.byTone[v].reduce((s, r) => s + r, 0) / x.byTone[v].length)))]);
        const w = new Array(16);
        for (let v = 0; v < 16; v++) {
          let lo = pts[0], hi = pts[pts.length - 1];
          for (const p of pts) { if (p[0] <= v) lo = p; if (p[0] >= v && hi[0] >= p[0]) hi = p; }
          if (pts.length === 1 || hi[0] === lo[0]) w[v] = Math.exp(lo[1]);
          else w[v] = Math.exp(lo[1] + (hi[1] - lo[1]) * (v - lo[0]) / (hi[0] - lo[0]));
          if (v < pts[0][0]) w[v] = Math.exp(pts[0][1]);
          if (v > pts[pts.length - 1][0]) w[v] = Math.exp(pts[pts.length - 1][1]);
        }
        return [x.d, w];
      });
    }

    // which of the band's 16 tones was sent: each candidate's expected pattern (the tone
    // and its ghosts) is compared with what was heard, and the best match wins
    symG(F, a, b) {
      if (!F.ghosts || !F.ghosts.length) return this.sym(F.band, a, b);
      const A = new Array(GRID_N);
      for (let t = 0; t < GRID_N; t++) A[t] = Math.sqrt(this.pow(t, a, b));
      let best = -1, bv = -1, sum = 0;
      for (let v = 0; v < 16; v++) {
        const g = F.band + v;
        let dot = A[g], norm = 1;
        for (const [d, w] of F.ghosts) {
          const t = g + d, wv = w[v], sw = Math.sqrt(wv);
          if (t >= 0 && t < GRID_N) { dot += sw * A[t]; norm += wv; }
        }
        const sc = dot / Math.sqrt(norm);
        const e = sc * sc;
        sum += e;
        if (e > bv) { bv = e; best = v; }
      }
      return { s: best, share: sum > 0 ? bv / sum : 0, p: bv };
    }

    win(start, D, k) {
      const a = start + Math.round(k * D + D * 0.25), b = start + Math.round(k * D + D * 0.9);
      return [a, Math.max(b, a + 1)];
    }

    // B: looking for preambles never stops, even while frames are being read
    search() {
      const now = this.n;
      for (let bi = 0; bi < BANDS.length; bi++) {
        const band = (BANDS[bi] - GRID_START) / GRID_STEP;
        for (let si = 0; si < SPEEDS.length; si++) {
          const key = bi * 4 + si;
          const D = SPEEDS[si] * 1000;
          const start = now - Math.round(PREAMBLE.length * D);
          let hit = null;
          if (start > 1) {
            // a burst of noise may drown one or two of the preamble's tones: 6 of 8 will do.
            // The expected tone may also come second, behind a "ghost" of itself (see learnGhosts)
            let sum = 0, miss = 0;
            for (let k = 0; k < PREAMBLE.length && miss <= 2; k++) {
              const [a, b] = this.win(start, D, k);
              const r = this.ranked(band, a, b, PREAMBLE[k]);
              if (!r.ok) { miss++; continue; }
              sum += r.share;
            }
            if (miss <= 2 && sum >= 0.45 * (PREAMBLE.length - miss)) hit = { score: sum, full: miss === 0, band, bandHz: BANDS[bi], si, D, start };
          }
          const c = this.cands.get(key);
          if (hit) {
            if (!c || hit.score >= c.score) this.cands.set(key, Object.assign(hit, { age: 0 }));
            else c.age = 0;
          } else if (c && ++c.age > 2) {
            this.cands.delete(key);
            // the same preamble may be seen in a neighbouring speed: keep the best one per start
            const dup = this.pending.find(p => Math.abs(p.pstart - c.start) < c.D * 2 && p.band === c.band);
            if (dup) { if (c.score > dup.score) Object.assign(dup, this.lockFrom(c)); }
            else this.pending.push(this.lockFrom(c));
          }
        }
      }
    }

    lockFrom(c) {
      return { band: c.band, bandHz: c.bandHz, si: c.si, D: c.D, score: c.score, full: c.full,
               start: c.start + Math.round(PREAMBLE.length * c.D), pstart: c.start };
    }

    // symbol k after the preamble (0..14 header, then body), o blocks later from symbol p on
    symAt(F, k, p, o) {
      const [a, b] = this.win(F.start + (k >= p ? o : 0), F.D, k);
      return this.symG(F, a, b);
    }

    // D: a block that does not check out is tried again with its least certain symbols set aside
    decodeBlock(w, conf, light) {
      let r = rsDecode(w);
      if (r || light) return r;
      const order = conf.map((c, i) => [c, i]).sort((x, y) => x[0] - y[0]).map(x => x[1]);
      for (let f = 1; f <= 4; f++) {
        r = rsDecode(w, order.slice(0, f));
        if (r) { this.stats.erased += f; return r; }
      }
      return null;
    }

    // the frame read as B body blocks, with a gap of o blocks before symbol p; null unless it all checks out
    decodeWith(F, B, p, o, light) {
      const K = B + 1, words = [], confs = [];
      for (let k = 0; k < K; k++) { words.push([]); confs.push([]); }
      for (let t = 0; t < K * 15; t++) {
        const r = this.symAt(F, t, p, o);
        words[t % K].push(r.s); confs[t % K].push(r.share);
      }
      const hr = this.decodeBlock(words[0], confs[0], light);
      if (!hr || hr.data[0] !== VERSION) return null;
      const d = hr.data;
      const h = { n: (d[1] << 4) | d[2], seq: (d[3] << 4) | d[4], doc: (d[5] << 4) | d[6],
                  L: (d[7] << 12) | (d[8] << 8) | (d[9] << 4) | d[10] };
      if (h.n > MAXLEN || bodyBlocks(h.n) !== B) return null;
      const nib = []; let fixed = hr.fixed;
      for (let k = 1; k < K; k++) {
        const r = this.decodeBlock(words[k], confs[k], light);
        if (!r) return null;
        fixed += r.fixed; nib.push(...r.data);
      }
      const by = [];
      for (let i = 0; i + 1 < nib.length; i += 2) by.push((nib[i] << 4) | nib[i + 1]);
      const off = (by[0] << 8) | by[1], bytes = by.slice(2, 2 + h.n);
      const crc = (by[2 + h.n] << 8) | by[3 + h.n];
      const all = [h.n, h.seq, h.doc, h.L >> 8, h.L & 255, off >> 8, off & 255].concat(bytes);
      if (crc16(all) !== crc) return null;
      return { seq: h.seq, doc: h.doc, L: h.L, o: off, bytes, fixed, B };
    }

    // power of a whole band over [a, b), per block
    bandPow(band, a, b) { let v = 0; for (let i = 0; i < 16; i++) v += this.pow(band + i, a, b); return v / Math.max(1, b - a); }

    // frames are tried at each possible size, smallest first, as soon as that much has been heard
    readPending() {
      const now = this.n, maxB = bodyBlocks(MAXLEN);
      for (let i = 0; i < this.pending.length; i++) {
        const F = this.pending[i];
        if (!F.B) {
          F.B = 1;
          // how loud the preamble was: the yardstick for "the frame has ended"
          F.ref = this.bandPow(F.band, F.pstart, F.start);
          this.learnGhosts(F);
        }
        let res = null;
        while (F.B <= maxB) {
          const [, e] = this.win(F.start, F.D, (F.B + 1) * 15 - 1);
          if (e > now) break;
          res = this.decodeWith(F, F.B, 1e9, 0);
          if (res) break;
          F.B++;
        }
        const maxO = Math.max(Math.round(F.D * 2.5), 80);
        if (!res) {
          // not readable at any size: wait until even the longest frame (and a gap) would be over,
          // then look for a gap in the sender's sound, at the sizes where its sound really ended
          const last = F.start + Math.round((maxB + 1) * 15 * F.D) + maxO + 20;
          if (last > now) continue;
          // (only for a clean preamble: a weak one may be nothing at all, and the search is costly)
          if (F.full) res = this.searchGaps(F, maxO);
        }
        this.pending.splice(i--, 1);
        if (!res) {
          if (F.full) { this.stats.bad++; this.onBad({ bandHz: F.bandHz, ms: Math.round(SPEEDS[F.si] * 1000) }); }
          continue;
        }
        const end = F.start + (res.gap || 0) + Math.round((res.B + 1) * 15 * F.D);
        this.pending = this.pending.filter(p => p.pstart < F.pstart || p.pstart >= end);
        i = -1;
        this.stats.frames++; this.stats.fixed += res.fixed;
        this.onFrame({ seq: res.seq, doc: res.doc, L: res.L, o: res.o, bytes: res.bytes,
                       bandHz: F.bandHz, ms: Math.round(SPEEDS[F.si] * 1000), fixed: res.fixed, gap: res.gap || 0 });
      }
    }

    searchGaps(F, maxO) {
      // where did the sound stop for 40 ms or more? each such place is a possible frame end
      const maxB = bodyBlocks(MAXLEN), stopAt = F.start + Math.round((maxB + 1) * 15 * F.D) + maxO;
      const sizes = new Set();
      let quiet = 0;
      for (let t = F.start + 15; t < stopAt; t += 5) {
        if (this.bandPow(F.band, t, t + 5) < 0.1 * F.ref) {
          if (++quiet === 8) {
            const len = (t - 35 - F.start) / F.D / 15;     // in blocks, gap included
            for (const B of [Math.round(len) - 1, Math.round(len) - 2, Math.floor(len) - 1])
              if (B >= 1 && B <= maxB) sizes.add(B);
          }
        } else quiet = 0;
      }
      if (!sizes.size) for (let B = 1; B <= maxB; B++) sizes.add(B);
      for (const B of sizes) { const r = this.searchGap(F, B, maxO); if (r) return r; }
      return null;
    }

    // only cheap decoding here; with interleaving a gap touches every block
    searchGap(F, B, maxO) {
      let best = null;
      const K = (B + 1) * 15, step = Math.max(1, Math.round(F.D / 8));
      for (let p = 0; p < K; p += 2) {
        for (let o = step; o <= maxO; o += step) {
          const t = this.decodeWith(F, B, p, o, true);
          if (t && (!best || t.fixed < best.fixed)) { best = t; best.gap = o; }
        }
        if (best && best.fixed === 0) break;
      }
      if (best) this.stats.gaps++;
      return best;
    }
  }

  // ---------- the mirror of the handheld's document ----------
  class Mirror {
    constructor() { this.doc = -1; this.bytes = new Uint8Array(1024); this.known = new Uint8Array(1024); this.L = 0; this.lastSeq = -1; }
    grow(n) {
      if (n <= this.bytes.length) return;
      let m = this.bytes.length; while (m < n) m *= 2;
      const b = new Uint8Array(m), k = new Uint8Array(m);
      b.set(this.bytes); k.set(this.known); this.bytes = b; this.known = k;
    }
    // returns 'new' when the handheld started a new document
    apply(f) {
      let fresh = false;
      if (f.doc !== this.doc) { this.doc = f.doc; this.L = 0; this.known.fill(0); fresh = true; }
      this.grow(Math.max(f.L, f.o + f.bytes.length));
      if (f.L < this.L) this.known.fill(0, f.L, this.L);
      this.L = f.L;
      for (let i = 0; i < f.bytes.length; i++) {
        const at = f.o + i;
        if (at >= f.L) break;
        this.bytes[at] = f.bytes[i]; this.known[at] = 1;
      }
      return fresh ? 'new' : 'ok';
    }
    firstUnknown(from) { for (let i = from || 0; i < this.L; i++) if (!this.known[i]) return i; return this.L; }
    // text of [a, b); missing bytes shown as the gap mark
    text(a, b, gapMark) {
      a = a || 0; b = b === undefined ? this.L : b;
      let out = '', i = a;
      const dec = new TextDecoder('utf-8');
      while (i < b) {
        if (!this.known[i]) { let j = i; while (j < b && !this.known[j]) j++; out += gapMark === undefined ? '·' : gapMark; i = j; continue; }
        let j = i; while (j < b && this.known[j]) j++;
        out += dec.decode(this.bytes.subarray(i, j));
        i = j;
      }
      return out;
    }
  }

  const api = { GRID_START, GRID_STEP, BANDS, SPEEDS, PREAMBLE, VERSION, MAXLEN,
                rsEncode, rsDecode, crc16, encodeFrame, synth, bodyBlocks, Receiver, Mirror };
  if (typeof module !== 'undefined' && module.exports) module.exports = api; else root.Whisper = api;
})(this);
