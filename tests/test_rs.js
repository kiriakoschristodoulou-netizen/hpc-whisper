// Reed-Solomon (15,11) over GF(16): errors, erasures and both together
const W = require('../modem.js');
const rnd = n => Math.random() * n | 0;
function trial(ne, nf) {
  const d = Array.from({ length: 11 }, () => rnd(16)), c = W.rsEncode(d);
  const idx = new Set(); while (idx.size < ne + nf) idx.add(rnd(15));
  const all = [...idx], errs = all.slice(0, ne), eras = all.slice(ne);
  for (const p of errs) c[p] ^= 1 + rnd(15);
  for (const p of eras) if (Math.random() < 0.8) c[p] ^= 1 + rnd(15);   // an erased symbol may still be right
  const r = W.rsDecode(c, eras);
  return r && r.data.join() === d.join();
}
let fail = 0;
for (const [ne, nf] of [[0, 0], [1, 0], [2, 0], [0, 1], [0, 2], [0, 3], [0, 4], [1, 1], [1, 2]])
  for (let t = 0; t < 3000; t++) if (!trial(ne, nf)) { fail++; if (fail < 5) console.log('failed', ne, 'errors', nf, 'erasures'); }
console.log(fail ? 'FAILURES ' + fail : 'all corrections within 2e+f<=4 succeeded');
if (fail) process.exit(1);
