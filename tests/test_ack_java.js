// The phone's acknowledgement (Ack.java): same symbols and hash as modem.js, and P / G read right from a mirror with a gap.
const cp = require('child_process'), fs = require('fs'), path = require('path');
const W = require('../modem.js');
let bad = 0;
function check(n, ok, d) { console.log((ok ? 'ok   ' : 'FAIL ') + n + (ok || !d ? '' : '  ' + d)); if (!ok) bad++; }
const dir = path.join(process.env.TMPDIR || '/tmp', 'ackjava'); fs.mkdirSync(dir, { recursive: true });
const src = path.join(__dirname, '..', 'android/app/src/main/java/net/kyriakos/whisper');
cp.execFileSync('javac', ['-d', dir, src + '/Ack.java', src + '/Receiver.java', src + '/Mirror.java', path.join(__dirname, 'java/AckTest.java')]);
const out = cp.execFileSync('java', ['-cp', dir, 'AckTest']).toString().trim().split('\n');
const text = Buffer.from('Hello world, this is a test of 27');
const hash = W.ackHash(77, 20, 6, text);
const exp = W.ackSymbols(77, 20, 6, hash);
check('P and G from the mirror, the hash', out[0].startsWith('77 20 6 ' + hash + ' :'), out[0]);
check('symbols equal modem.js', out[0].split(':')[1].trim() === exp.join(' '), out[0]);
check('a prefix of 21 with a gap of 5', out[1] === '21 5', out[1]);
check('everything held: no gap', out[2] === '33 0', out[2]);
check('sound length', Number(out[3]) === Math.round(23 * 0.032 * 48000) + 2 * Math.round(48000 * 0.02), out[3]);
process.exit(bad ? 1 : 0);
