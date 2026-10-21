package net.kyriakos.whisper.gateway;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.List;

/** What the service tells the screen: a few numbers and the last lines of what happened. */
final class State {
    private State() {}
    static volatile boolean running;
    static volatile String problem = "";
    static volatile long startedAt, lastHeardAt;
    static volatile int rate;
    static volatile String source = "";
    static volatile long framesHeard, turns, bytesUp, bytesDown;
    static volatile int connections;
    static volatile int level;                       // loudest sample of the last second, 0..100
    private static final ArrayDeque<String> LOG = new ArrayDeque<>();

    static synchronized void log(String s) {
        LOG.addLast(new java.text.SimpleDateFormat("HH:mm:ss", java.util.Locale.US).format(new java.util.Date()) + "  " + s);
        while (LOG.size() > 60) LOG.removeFirst();
    }

    static synchronized List<String> lines() { return new ArrayList<>(LOG); }
}
