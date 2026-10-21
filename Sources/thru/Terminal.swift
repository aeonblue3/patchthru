import Darwin
import Foundation

/// Minimal full-screen terminal control: alternate screen, hidden cursor, no-echo non-canonical input.
/// Signals stay enabled (ISIG), so Ctrl-C still reaches the normal SIGINT handler. restore() is idempotent and is
/// registered with atexit plus the fatal-signal handlers, so the terminal comes back on every exit path.
enum Term {
    static var saved = termios()
    static var active = false

    static var isInteractive: Bool {
        isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0 && ProcessInfo.processInfo.environment["TERM"] != "dumb"
    }

    static func size() -> (width: Int, height: Int) {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0, ws.ws_row > 0 {
            return (Int(ws.ws_col), Int(ws.ws_row))
        }
        return (80, 24)
    }

    private static func put(_ s: String) {
        var bytes = Array(s.utf8)[...]
        while !bytes.isEmpty {
            let n = bytes.withUnsafeBytes { write(STDOUT_FILENO, $0.baseAddress, $0.count) }
            if n <= 0 { return }
            bytes = bytes.dropFirst(n)
        }
    }

    static func enter() {
        guard !active, isInteractive else { return }
        tcgetattr(STDIN_FILENO, &saved)
        var raw = saved
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
        withUnsafeMutablePointer(to: &raw.c_cc) { p in
            p.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) {
                $0[Int(VMIN)] = 1
                $0[Int(VTIME)] = 0
            }
        }
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        put("\u{1B}[?1049h\u{1B}[?25l\u{1B}[2J")
        active = true
        atexit { Term.restore() }
        for sig in [SIGHUP, SIGSEGV, SIGILL, SIGTRAP, SIGABRT, SIGBUS] {
            signal(sig) { s in
                Term.restore()
                signal(s, SIG_DFL)
                raise(s)
            }
        }
    }

    static func restore() {
        guard active else { return }
        active = false
        put("\u{1B}[?25h\u{1B}[?1049l")
        tcsetattr(STDIN_FILENO, TCSANOW, &saved)
    }

    /// Draw lines from the top-left, clearing the rest of each row and everything below.
    static func draw(_ lines: [String], height: Int) {
        var out = ""
        let shown = lines.prefix(height)
        for (i, l) in shown.enumerated() { out += "\u{1B}[\(i + 1);1H" + l + "\u{1B}[K" }
        out += "\u{1B}[\(shown.count + 1);1H\u{1B}[J"
        put(out)
    }

    static func clear() { put("\u{1B}[2J") }
}
