#!/usr/bin/env python3
"""End to end: the handheld program (Pascal netsim) and the phone program (Java
E2ESim) over a simulated room, with the Linux kernel's TCP as Windows (a TUN
device 192.168.55.2) and a local web server as the internet.

  python3 e2e.py            (from gateway/tests; needs lx/netsim and the Java classes in $CLS)
"""
import os, sys, struct, fcntl, socket, subprocess, threading, time, hashlib, http.server, socketserver, functools

CLS = os.environ.get('CLS', '/home/claude/gwbuild')
HERE = os.path.dirname(os.path.abspath(__file__))
fails = 0

def check(ok, what):
    global fails
    print(('PASS  ' if ok else 'FAIL  ') + what, flush=True)
    if not ok: fails += 1

# ---- the "internet": a web server on 127.0.0.1:8080 ----
PAGES = {
    '/small.txt': b'Hello from the internet through sound.\n',
    '/page.html': (b'<html><body>' + b''.join(b'<p>line %d of the test page</p>\n' % i for i in range(60)) + b'</body></html>'),
    '/data.bin': bytes((i * 7 + i // 256) & 255 for i in range(6000)),
}
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.0'
    def do_GET(self):
        body = PAGES.get(self.path)
        if body is None:
            self.send_response(404); self.end_headers(); return
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
class Srv(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True; allow_reuse_address = True
web = Srv(('127.0.0.1', 8080), H)
threading.Thread(target=web.serve_forever, daemon=True).start()

class Echo(socketserver.BaseRequestHandler):
    def handle(self):
        while True:
            d = self.request.recv(100)
            if not d: break
            self.request.sendall(d)
echo = Srv(('127.0.0.1', 8081), Echo)
threading.Thread(target=echo.serve_forever, daemon=True).start()
uecho = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); uecho.bind(('127.0.0.1', 8082))
def uloop():
    while True:
        d, a = uecho.recvfrom(300); uecho.sendto(d.upper(), a)
threading.Thread(target=uloop, daemon=True).start()

# ---- the phone ----
java = subprocess.Popen(['java', '-cp', CLS, 'E2ESim'] + (['trace'] if os.environ.get('TRACE') else []),
                        stdout=subprocess.PIPE, stderr=sys.stderr, env=dict(os.environ, JAVA_TOOL_OPTIONS=''))
port = int(java.stdout.readline().split()[1])

# ---- Windows: a TUN device ----
tun = os.open('/dev/net/tun', os.O_RDWR)
fcntl.ioctl(tun, 0x400454ca, struct.pack('16sH22x', b'wn0', 0x0001 | 0x1000))
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
def sa(ip): return struct.pack('H2s4s8x', socket.AF_INET, b'\0\0', socket.inet_aton(ip))
fcntl.ioctl(s, 0x8916, struct.pack('16s16s', b'wn0', sa('192.168.55.2')))
fcntl.ioctl(s, 0x891c, struct.pack('16s16s', b'wn0', sa('255.255.255.0')))
fcntl.ioctl(s, 0x8914, struct.pack('16sH22x', b'wn0', 0x1 | 0x40))
fcntl.ioctl(s, 0x8922, struct.pack('16sI12x', b'wn0', 1400))        # MTU

# ---- the handheld ----
hh = subprocess.Popen([os.path.join(HERE, 'lx', 'netsim'), '127.0.0.1', str(port), 'v'],
                      stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=sys.stderr, bufsize=0)
def tun_to_hh():
    try:
        while True:
            p = os.read(tun, 2000)
            hh.stdin.write(struct.pack('>H', len(p)) + p)
    except Exception: pass
def hh_to_tun():
    buf = b''
    try:
        while True:
            d = hh.stdout.read(1) if False else os.read(hh.stdout.fileno(), 4096)
            if not d: break
            buf += d
            while len(buf) >= 2:
                n = struct.unpack('>H', buf[:2])[0]
                if len(buf) < 2 + n: break
                os.write(tun, buf[2:2 + n]); buf = buf[2 + n:]
    except Exception: pass
threading.Thread(target=tun_to_hh, daemon=True).start()
threading.Thread(target=hh_to_tun, daemon=True).start()
time.sleep(0.3)

def curl(path, port=8080, maxt=600):
    t = time.time()
    r = subprocess.run(['curl', '-s', '--noproxy', '*', '--max-time', str(maxt), 'http://192.168.55.77:%d%s' % (port, path)],
                       capture_output=True)
    return r.returncode, r.stdout, time.time() - t

which = sys.argv[1:] or ['dns', 'small', 'echo', 'udp', 'page', 'data', 'notfound', 'refused']

def dnsq(name, server='192.168.55.1', timeout=300):
    q = struct.pack('>HHHHHH', 0x1234, 0x0100, 1, 0, 0, 0)
    for l in name.split('.'): q += bytes([len(l)]) + l.encode()
    q += b'\0' + struct.pack('>HH', 1, 1)
    u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); u.settimeout(timeout); u.bind(('192.168.55.2', 0))
    u.sendto(q, (server, 53))
    try:
        d, _ = u.recvfrom(600)
    except socket.timeout:
        return None
    n = struct.unpack('>H', d[6:8])[0]
    # skip the question
    p = 12
    while d[p]: p += d[p] + 1
    p += 5
    addrs = []
    for i in range(n):
        p += 2 + 8; rl = struct.unpack('>H', d[p:p+2])[0]; p += 2
        addrs.append(socket.inet_ntoa(d[p:p+4])); p += rl
    return (d[3] & 15, addrs)

try:
    if 'dns' in which:
        t = time.time(); r = dnsq('localhost'); print('      (%.1f s)' % (time.time() - t))
        check(r == (0, ['127.0.0.1']), 'DNS: localhost -> %s' % (r,))
        t = time.time(); r2 = dnsq('localhost'); 
        check(r2 == (0, ['127.0.0.1']) and time.time() - t < 3, 'DNS: second ask answered at once from the cache (%.2f s)' % (time.time() - t))
    if "small" in which:
        rc, body, dt = curl('/small.txt')
        check(rc == 0 and body == PAGES['/small.txt'], 'HTTP small file through the sound link (%d bytes, %.1f s wall)' % (len(body), dt))
    if 'echo' in which:
        c = socket.create_connection(('192.168.55.77', 8081), timeout=300)
        c.sendall(b'abcdefghij' * 5); got = b''
        while len(got) < 50:
            d = c.recv(100)
            if not d: break
            got += d
        c.close()
        check(got == b'abcdefghij' * 5, 'TCP echo both ways (%d bytes)' % len(got))
    if 'udp' in which:
        u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); u.settimeout(300); u.bind(('192.168.55.2', 0))
        u.sendto(b'ping over sound', ('192.168.55.88', 8082))
        # 192.168.55.88 is not remapped by the gateway: use the mapped address
        u.sendto(b'ping over sound', ('192.168.55.77', 8082))
        try: d, a = u.recvfrom(100)
        except socket.timeout: d = None
        check(d == b'PING OVER SOUND', 'UDP datagram and its reply: %r' % (d,))
    if 'page' in which:
        rc, body, dt = curl('/page.html')
        check(rc == 0 and body == PAGES['/page.html'], 'HTTP page %d bytes (%.1f s wall)' % (len(body), dt))
    if 'data' in which:
        rc, body, dt = curl('/data.bin')
        check(rc == 0 and hashlib.md5(body).digest() == hashlib.md5(PAGES['/data.bin']).digest(), 'HTTP binary file 6000 bytes: got %d (%.1f s wall)' % (len(body), dt))
    if 'notfound' in which:
        rc, body, dt = curl('/nothing')
        check(rc == 0 and body == b'', 'HTTP 404 handled (%.1f s wall)' % dt)
    if 'refused' in which:
        rc, body, dt = curl('/x', port=9, maxt=300)
        check(rc != 0, 'closed port -> connection refused/reset (curl exit %d, %.1f s wall)' % (rc, dt))
finally:
    try: hh.stdin.close()
    except Exception: pass
    time.sleep(0.5)
    hh.terminate(); java.terminate()
print('%d failed' % fails if fails else 'all passed')
sys.exit(1 if fails else 0)
