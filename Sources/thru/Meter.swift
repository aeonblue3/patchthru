import Foundation

func linearToDB(_ x: Float) -> Double {
    x <= 1e-6 ? -120 : 20 * log10(Double(x))
}

/// Peak-meter ballistics: instant attack, 24 dB/s release; peak hold 1.5 s then 24 dB/s; latched clip.
struct MeterChannel {
    var level = -120.0
    var hold = -120.0
    var holdAge = 0.0
    var clip = false

    mutating func update(peak: Float, dt: Double, detectClip: Bool) {
        let db = linearToDB(peak)
        level = max(db, level - 24 * dt)
        if db >= hold {
            hold = db
            holdAge = 0
        } else {
            holdAge += dt
            if holdAge > 1.5 { hold = max(level, hold - 24 * dt) }
        }
        if detectClip && peak >= 0.999 { clip = true }
    }

    mutating func clear() {
        clip = false
        hold = level
        holdAge = 0
    }
}

/// Full-screen meter. Owns the terminal while active; all calls happen on the main queue.
final class MeterUI {
    private var outputs: [MeterChannel] = []
    private var inputs: [MeterChannel] = []
    private var route = ""
    private var detail = ""
    private var state = "waiting"
    private var outLabels: [String] = []
    private var inLabels: [String] = []
    private var events: [String] = []
    private var showInputs = false
    private var lastSize = (width: 0, height: 0)
    private var lastFrame = DispatchTime.now()
    private var timer: DispatchSourceTimer?
    private var keys: DispatchSourceRead?
    private let engine: () -> Engine?
    private let quit: () -> Void
    private let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    init(engine: @escaping () -> Engine?, quit: @escaping () -> Void, route: String) {
        self.engine = engine
        self.quit = quit
        self.route = route
    }

    func start() {
        Term.enter()
        signal(SIGWINCH, SIG_IGN)
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: .milliseconds(33))
        t.setEventHandler { [weak self] in self?.frame() }
        t.resume()
        timer = t
        let k = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
        k.setEventHandler { [weak self] in self?.readKeys() }
        k.resume()
        keys = k
    }

    func shutdown() {
        timer?.cancel()
        keys?.cancel()
        timer = nil
        keys = nil
        Term.restore()
    }

    func connected(route: String, detail: String, outChannels: [Int], inChannels: [Int]) {
        self.route = route
        self.detail = detail
        outLabels = outChannels.map { "OUT \($0 + 1)" }
        inLabels = inChannels.map { "IN \($0 + 1)" }
        if outputs.count != outChannels.count { outputs = Array(repeating: MeterChannel(), count: outChannels.count) }
        if inputs.count != inChannels.count { inputs = Array(repeating: MeterChannel(), count: inChannels.count) }
    }

    func setState(_ s: String) { state = s }

    func addEvent(_ line: String) {
        events.append("\(clock.string(from: Date())) \(line)")
        if events.count > 20 { events.removeFirst(events.count - 20) }
    }

    private func readKeys() {
        var buf = [UInt8](repeating: 0, count: 16)
        let n = read(STDIN_FILENO, &buf, buf.count)
        guard n > 0 else { return }
        for b in buf.prefix(n) {
            switch b {
            case UInt8(ascii: "q"), UInt8(ascii: "Q"): quit()
            case UInt8(ascii: "c"), UInt8(ascii: "C"):
                for i in outputs.indices { outputs[i].clear() }
                for i in inputs.indices { inputs[i].clear() }
            case UInt8(ascii: "i"), UInt8(ascii: "I"): showInputs.toggle()
            default: break
            }
        }
    }

    private func frame() {
        let now = DispatchTime.now()
        let dt = min(0.25, Double(now.uptimeNanoseconds &- lastFrame.uptimeNanoseconds) / 1e9)
        lastFrame = now
        let peaks = engine()?.takeChannelPeaks() ?? (inputs: [], outputs: [])
        for i in outputs.indices { outputs[i].update(peak: i < peaks.outputs.count ? peaks.outputs[i] : 0, dt: dt, detectClip: true) }
        for i in inputs.indices { inputs[i].update(peak: i < peaks.inputs.count ? peaks.inputs[i] : 0, dt: dt, detectClip: false) }

        let size = Term.size()
        if size != lastSize { Term.clear(); lastSize = size }
        let f = MeterFrame(
            route: route, detail: detail,
            outLabels: outLabels, outDB: outputs.map { $0.level }, outHoldDB: outputs.map { $0.hold }, outClip: outputs.map { $0.clip },
            inLabels: inLabels, inDB: inputs.map { $0.level }, inHoldDB: inputs.map { $0.hold },
            showInputs: showInputs, state: state, events: events,
            color: ProcessInfo.processInfo.environment["NO_COLOR"] == nil)
        Term.draw(renderMeter(f, width: size.width, height: size.height), height: size.height)
    }
}
