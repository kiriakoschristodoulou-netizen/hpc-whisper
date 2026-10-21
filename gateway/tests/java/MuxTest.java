import java.io.*;
import java.net.*;
import java.util.*;
import net.kyriakos.whisper.gw.*;

/** The gateway's mux against real local sockets, driven by hand-made handheld messages. */
public class MuxTest {
    static int fails = 0, checks = 0;
    static void check(boolean ok, String what) { checks++; if (!ok) fails++; System.out.println((ok ? "PASS  " : "FAIL  ") + what); }
    static byte[] b(int... v) { byte[] r = new byte[v.length]; for (int i = 0; i < v.length; i++) r[i] = (byte) v[i]; return r; }
    static void feed(Gateway g, byte[] m) { g.feed(m, 0, m.length); }

    public static void main(String[] x) throws Exception {
        Gateway g = new Gateway(null);
        // an echo server that closes when its input ends
        ServerSocket ss = new ServerSocket(0, 5, InetAddress.getByName("127.0.0.1"));
        int port = ss.getLocalPort();
        Thread srv = new Thread(() -> {
            try { while (true) { Socket s = ss.accept(); new Thread(() -> { try { InputStream in = s.getInputStream(); OutputStream o = s.getOutputStream(); byte[] bb = new byte[100]; int n; while ((n = in.read(bb)) > 0) { o.write(bb, 0, n); o.flush(); } s.close(); } catch (IOException e) {} }).start(); } } catch (IOException e) {}
        });
        srv.setDaemon(true); srv.start();
        DatagramSocket us = new DatagramSocket(0, InetAddress.getByName("127.0.0.1"));
        Thread usrv = new Thread(() -> { try { byte[] bb = new byte[300]; while (true) { DatagramPacket p = new DatagramPacket(bb, bb.length); us.receive(p); us.send(new DatagramPacket(bb, p.getLength(), p.getSocketAddress())); } } catch (IOException e) {} });
        usrv.setDaemon(true); usrv.start();

        feed(g, b(0x07, 1));
        byte[] m = g.awaitDown(1000);
        check(m != null && m[0] == (byte) 0x87 && m[1] == 1, "HELLO answered");

        feed(g, new byte[]{0x05, 9, 9, 'l', 'o', 'c', 'a', 'l', 'h', 'o', 's', 't'}.length == 12 ? new byte[]{0x05, 9, 9, 'l', 'o', 'c', 'a', 'l', 'h', 'o', 's', 't'} : null);
        m = g.awaitDown(3000);
        check(m != null && m[0] == (byte) 0x85 && m[1] == 9 && m[2] == 1 && m[3] == 127 && m[6] == 1, "DNS localhost -> 127.0.0.1");
        feed(g, new byte[]{0x05, 10, 19, 'n', 'o', 't', '-', 'a', '-', 'n', 'a', 'm', 'e', '.', 'i', 'n', 'v', 'a', 'l', 'i', 'd', '.'});
        m = g.awaitDown(8000);
        check(m != null && m[0] == (byte) 0x85 && m[1] == 10 && m[2] == 0, "DNS of a name that does not exist -> no addresses");

        // TCP: open, send in two messages split across feed calls, get the echo, close
        byte[] open = b(0x01, 5, 127, 0, 0, 1, port >> 8, port & 255);
        g.feed(open, 0, 3); g.feed(open, 3, 5);
        m = g.awaitDown(2000);
        check(m != null && m[0] == (byte) 0x81 && m[1] == 5, "OPEN -> OPENED (message split in two pieces)");
        feed(g, b(0x02, 5, 5, 'h', 'e', 'l', 'l', 'o'));
        StringBuilder got = new StringBuilder();
        for (int i = 0; i < 5 && got.length() < 5; i++) { m = g.awaitDown(1000); if (m != null && m[0] == (byte) 0x82) got.append(new String(m, 3, m[2] & 255)); }
        check(got.toString().equals("hello"), "DATA echoed back: " + got);
        feed(g, b(0x03, 5));
        m = g.awaitDown(2000);
        check(m != null && m[0] == (byte) 0x83 && m[1] == 5, "CLOSE from the handheld -> the server closes -> CLOSE down");
        feed(g, b(0x04, 5));

        // refused
        ServerSocket tmp = new ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")); int dead = tmp.getLocalPort(); tmp.close();
        feed(g, b(0x01, 6, 127, 0, 0, 1, dead >> 8, dead & 255));
        m = g.awaitDown(3000);
        check(m != null && m[0] == (byte) 0x84 && m[1] == 6 && m[2] == 1, "connection refused -> FAIL 1");

        // UDP
        feed(g, b(0x06, 7, 127, 0, 0, 1, us.getLocalPort() >> 8, us.getLocalPort() & 255, 3, 'a', 'b', 'c'));
        m = g.awaitDown(3000);
        check(m != null && m[0] == (byte) 0x86 && m[1] == 7 && m[2] == 3 && m[3] == 'a', "UDP datagram and its reply");

        // a big download: the server side sends more than the queue limit; pump through a Link-sized window
        ServerSocket big = new ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"));
        Thread bt = new Thread(() -> { try { Socket s = big.accept(); OutputStream o = s.getOutputStream(); byte[] d = new byte[20000]; for (int i = 0; i < d.length; i++) d[i] = (byte) i; o.write(d); o.flush(); s.close(); } catch (IOException e) {} });
        bt.setDaemon(true); bt.start();
        feed(g, b(0x01, 8, 127, 0, 0, 1, big.getLocalPort() >> 8, big.getLocalPort() & 255));
        int total = 0; boolean order = true, closed = false;
        m = g.awaitDown(2000);
        while (m != null) {
            if (m[0] == (byte) 0x82) { for (int i = 0; i < (m[2] & 255); i++) if (m[3 + i] != (byte) (total + i)) order = false; total += m[2] & 255; }
            if (m[0] == (byte) 0x83) { closed = true; break; }
            m = g.awaitDown(2000);
        }
        check(total == 20000 && order && closed, "20,000 bytes downloaded in order (" + total + "), then CLOSE");

        feed(g, b(0x09));
        g.close();
        System.out.println(checks - fails + " of " + checks + " checks passed");
        System.exit(fails > 0 ? 1 : 0);
    }
}
