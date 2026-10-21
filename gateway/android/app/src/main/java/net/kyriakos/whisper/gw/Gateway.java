package net.kyriakos.whisper.gw;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.util.ArrayDeque;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.LinkedBlockingQueue;

/**
 * The gateway's mux (NET-PROTOCOL.md section 4): messages from the handheld
 * become real connections, lookups and datagrams on the internet; the answers
 * wait here until the turn logic pumps them into the link.
 */
public final class Gateway {
    public interface Log { void log(String s); }

    private final ExecutorService pool = Executors.newCachedThreadPool(r -> { Thread t = new Thread(r, "gw"); t.setDaemon(true); return t; });
    private final Log log;
    private final Object lock = new Object();
    private final ArrayDeque<byte[]> down = new ArrayDeque<>();
    private final Map<Integer, Conn> conns = new HashMap<>();
    private byte[] up = new byte[0];
    private boolean closed;
    public volatile int connectTimeoutMs = 8000;
    /** Test hook: maps the address a connection is opened to (null = as asked). */
    public volatile java.util.function.UnaryOperator<String> remap;

    public long bytesUp, bytesDown, opened, lookups;

    public Gateway(Log log) { this.log = log != null ? log : s -> {}; }

    private static final class Conn {
        final int id; Socket s; OutputStream out;
        final LinkedBlockingQueue<byte[]> wq = new LinkedBlockingQueue<>();
        int queuedDown;                 // bytes of this connection waiting in `down`
        boolean closedUp;               // the handheld sent CLOSE
        volatile boolean dead;
        Conn(int id) { this.id = id; }
    }

    // ---------- from the handheld ----------

    /** Stream bytes from the handheld (any pieces). */
    public void feed(byte[] b, int off, int len) {
        synchronized (lock) {
            byte[] n = new byte[up.length + len];
            System.arraycopy(up, 0, n, 0, up.length);
            System.arraycopy(b, off, n, up.length, len);
            up = n;
            bytesUp += len;
            while (true) {
                int need = msgLen(up);
                if (need == -2) { log.log("unknown message, stream dropped"); up = new byte[0]; return; }
                if (need < 0 || up.length < need) return;
                byte[] m = new byte[need];
                System.arraycopy(up, 0, m, 0, need);
                byte[] rest = new byte[up.length - need];
                System.arraycopy(up, need, rest, 0, rest.length);
                up = rest;
                handle(m);
            }
        }
    }

    /** Length of the first message in a, -1 if more is needed to know, -2 if its type is unknown. */
    static int msgLen(byte[] a) {
        if (a.length == 0) return -1;
        switch (a[0]) {
            case 0x01: return 8;
            case 0x02: return a.length < 3 ? -1 : 3 + (a[2] & 255);
            case 0x03: case 0x04: return 2;
            case 0x05: return a.length < 3 ? -1 : 3 + (a[2] & 255);
            case 0x06: return a.length < 9 ? -1 : 9 + (a[8] & 255);
            case 0x07: return 2;
            default: return -2;
        }
    }

    private void handle(byte[] m) {
        int type = m[0];
        switch (type) {
            case 0x07:
                closeAll();
                send(new byte[]{(byte) 0x87, 1}, true);
                break;
            case 0x01: open(m[1] & 255, m); break;
            case 0x02: {
                Conn c = conns.get(m[1] & 255);
                if (c != null && !c.dead) { byte[] d = new byte[m[2] & 255]; System.arraycopy(m, 3, d, 0, d.length); c.wq.add(d); }
                break;
            }
            case 0x03: {
                Conn c = conns.get(m[1] & 255);
                if (c != null) { c.closedUp = true; c.wq.add(new byte[0]); }
                break;
            }
            case 0x04: {
                Conn c = conns.remove(m[1] & 255);
                if (c != null) kill(c);
                break;
            }
            case 0x05: lookup(m[1] & 255, new String(m, 3, m[2] & 255, java.nio.charset.StandardCharsets.US_ASCII)); break;
            case 0x06: udp(m); break;
        }
    }

    private void open(int id, byte[] m) {
        Conn old = conns.remove(id);
        if (old != null) kill(old);
        final Conn c = new Conn(id);
        conns.put(id, c);
        String h0 = (m[2] & 255) + "." + (m[3] & 255) + "." + (m[4] & 255) + "." + (m[5] & 255);
        final String host = remap != null ? remap.apply(h0) : h0;
        final int port = ((m[6] & 255) << 8) | (m[7] & 255);
        opened++;
        pool.execute(() -> {
            try {
                Socket s = new Socket();
                s.connect(new InetSocketAddress(host, port), connectTimeoutMs);
                s.setTcpNoDelay(true);
                synchronized (lock) {
                    if (c.dead) { s.close(); return; }
                    c.s = s; c.out = s.getOutputStream();
                    send(new byte[]{(byte) 0x81, (byte) id}, false);
                }
                pool.execute(() -> writer(c));
                reader(c);
            } catch (SocketTimeoutException e) {
                fail(c, 2);
            } catch (IOException e) {
                String msg = String.valueOf(e.getMessage());
                fail(c, msg.contains("refused") ? 1 : 2);
            }
        });
        log.log("open " + id + " " + host + ":" + port);
    }

    private void fail(Conn c, int reason) {
        synchronized (lock) {
            if (conns.get(c.id) != c) return;
            conns.remove(c.id);
            c.dead = true;
            send(new byte[]{(byte) 0x84, (byte) c.id, (byte) reason}, false);
        }
    }

    private void writer(Conn c) {
        try {
            while (!c.dead) {
                byte[] d = c.wq.take();
                if (d.length == 0) {                // CLOSE: no more from the handheld
                    try { c.s.shutdownOutput(); } catch (IOException e) { /* already closed */ }
                    return;
                }
                c.out.write(d);
                c.out.flush();
            }
        } catch (IOException | InterruptedException e) {
            fail(c, 3);
            kill(c);
        }
    }

    private void reader(Conn c) {
        byte[] buf = new byte[200];
        try {
            InputStream in = c.s.getInputStream();
            while (!c.dead) {
                synchronized (lock) {
                    while (c.queuedDown > 1000 && !c.dead && !closed) {
                        try { lock.wait(500); } catch (InterruptedException e) { return; }
                    }
                }
                int n = in.read(buf);
                if (n < 0) break;
                if (n == 0) continue;
                byte[] m = new byte[3 + n];
                m[0] = (byte) 0x82; m[1] = (byte) c.id; m[2] = (byte) n;
                System.arraycopy(buf, 0, m, 3, n);
                synchronized (lock) { if (c.dead) return; c.queuedDown += n; send(m, false, c); }
            }
            synchronized (lock) { if (!c.dead) send(new byte[]{(byte) 0x83, (byte) c.id}, false); }
            // the connection stays until the handheld closes or aborts it
        } catch (IOException e) {
            synchronized (lock) {
                if (!c.dead) { send(new byte[]{(byte) 0x84, (byte) c.id, 3}, false); c.dead = true; conns.remove(c.id); }
            }
            kill(c);
        }
    }

    private void kill(Conn c) {
        c.dead = true;
        c.wq.add(new byte[0]);
        try { if (c.s != null) c.s.close(); } catch (IOException e) { /* closing */ }
        synchronized (lock) { lock.notifyAll(); }
    }

    private void closeAll() {
        synchronized (lock) {
            for (Conn c : conns.values()) kill(c);
            conns.clear();
            down.clear();
        }
    }

    public void reset() { closeAll(); synchronized (lock) { up = new byte[0]; } }

    public void close() { synchronized (lock) { closed = true; } closeAll(); pool.shutdownNow(); }

    private void lookup(int qid, String name) {
        lookups++;
        pool.execute(() -> {
            ByteArrayOutputStream o = new ByteArrayOutputStream();
            int cnt = 0;
            try {
                for (InetAddress a : InetAddress.getAllByName(name))
                    if (a instanceof Inet4Address && cnt < 4) { o.write(a.getAddress()); cnt++; }
            } catch (Exception e) { cnt = 0; o.reset(); }
            byte[] m = new byte[3 + o.size()];
            m[0] = (byte) 0x85; m[1] = (byte) qid; m[2] = (byte) cnt;
            System.arraycopy(o.toByteArray(), 0, m, 3, o.size());
            synchronized (lock) { send(m, true); }
            log.log("dns " + name + " -> " + cnt);
        });
    }

    private void udp(byte[] m) {
        final int id = m[1] & 255;
        String h1 = (m[2] & 255) + "." + (m[3] & 255) + "." + (m[4] & 255) + "." + (m[5] & 255);
        final String host = remap != null ? remap.apply(h1) : h1;
        final int port = ((m[6] & 255) << 8) | (m[7] & 255);
        final byte[] d = new byte[m[8] & 255];
        System.arraycopy(m, 9, d, 0, d.length);
        pool.execute(() -> {
            try (DatagramSocket s = new DatagramSocket()) {
                s.send(new DatagramPacket(d, d.length, InetAddress.getByName(host), port));
                s.setSoTimeout(5000);
                byte[] r = new byte[255];
                for (int i = 0; i < 4; i++) {
                    DatagramPacket p = new DatagramPacket(r, r.length);
                    s.receive(p);
                    byte[] out = new byte[3 + p.getLength()];
                    out[0] = (byte) 0x86; out[1] = (byte) id; out[2] = (byte) p.getLength();
                    System.arraycopy(r, 0, out, 3, p.getLength());
                    synchronized (lock) { send(out, false); }
                    s.setSoTimeout(500);
                }
            } catch (IOException e) { /* no (more) replies */ }
        });
    }

    // ---------- to the handheld ----------

    private void send(byte[] m, boolean first) { send(m, first, null); }

    private void send(byte[] m, boolean first, Conn c) {
        synchronized (lock) {
            if (first) down.addFirst(m); else down.addLast(m);
            lock.notifyAll();
        }
    }

    /** Move waiting messages into the link while it holds less than `limit` bytes. */
    public void pump(Link link, int limit) {
        synchronized (lock) {
            while (!down.isEmpty()) {
                byte[] m = down.peekFirst();
                if (link.pending() >= limit || link.free() < m.length) break;
                down.pollFirst();
                link.write(m, 0, m.length);
                bytesDown += m.length;
                if ((m[0] & 255) == 0x82) {
                    Conn c = conns.get(m[1] & 255);
                    if (c != null) { c.queuedDown -= m[2] & 255; lock.notifyAll(); }
                }
            }
        }
    }

    /** Something waits to be sent. */
    public boolean hasDown() { synchronized (lock) { return !down.isEmpty(); } }

    /** Connections open (for the screen). */
    public int connections() { synchronized (lock) { return conns.size(); } }

    /** Test helper: take the next message waiting for the handheld, or null. */
    public byte[] pollDown() { synchronized (lock) { return down.pollFirst(); } }

    /** Test helper: wait up to ms for a message. */
    public byte[] awaitDown(long ms) throws InterruptedException {
        long end = System.currentTimeMillis() + ms;
        synchronized (lock) {
            while (down.isEmpty()) {
                long left = end - System.currentTimeMillis();
                if (left <= 0) return null;
                lock.wait(left);
            }
            byte[] m = down.pollFirst();
            if ((m[0] & 255) == 0x82) { Conn c = conns.get(m[1] & 255); if (c != null) c.queuedDown -= m[2] & 255; }
            return m;
        }
    }
}
