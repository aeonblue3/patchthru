import CoreAudio
import Foundation

struct RouteConfig: Codable {
    var inputText: String
    var outputText: String
    var map: String?
    var buffer: Int
    var gain: Float
    var noWait: Bool = false
    var meter: Bool = false

    private enum CodingKeys: String, CodingKey { case inputText, outputText, map, buffer, gain }
}

/// While the full-screen meter owns the terminal, events go to its event area instead of scrolling the screen.
var eventSink: ((String) -> Void)?

func say(_ line: String) {
    if let sink = eventSink { sink(line); return }
    print("thru: \(line)")
    fflush(stdout)
}

func fail(_ line: String, code: Int32) -> Never {
    Term.restore()   // the message must land on the real screen, not the meter's
    FileHandle.standardError.write(Data("thru: \(line)\n".utf8))
    exit(code)
}

enum SavedRoute {
    static var url: URL {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent(".config/thru/last.json")
    }
    static func load() -> RouteConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RouteConfig.self, from: data)
    }
    static func save(_ cfg: RouteConfig) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(cfg) { try? data.write(to: url, options: .atomic) }
    }
}

/// Main-queue supervisor: finds both devices (waiting if needed), builds the engine, watches its health, and rebuilds it.
/// The aggregate rejoins a replugged device by itself, so a device that is merely absent is never a reason to rebuild.
/// Rebuild only when the audio callback stalls or the layout stays wrong for 3 s with both devices present.
final class Router {
    private let cfg: RouteConfig
    private var engine: Engine?
    private var input: AudioDevice?
    private var output: AudioDevice?
    private var announcedWaiting = Set<String>()
    private var present: [String: Bool] = [:]
    private var rateComplaint = ""
    private var lastFailure = ""
    private var buildFailures = 0
    private var everConnected = false
    private var asleep = false
    private var sleptWall = 0.0
    private var sleptUp: UInt64 = 0
    private var pinnedSpec: String?     // channel map chosen at first connect; rebuilds reuse it, never re-guess
    private var connectedTick = 0
    private var layoutRebuilds = 0
    private var lastFaults: UInt32 = 0

    // Health tracking, in 100 ms ticks.
    private var ticks = 0
    private var lastCalls: UInt64 = 0
    private var stalled = 0
    private var badTicks = 0
    private var goodTicks = 0
    private var orderOK = true
    private var muted = false
    private var debugRebuildTick: Int?
    private let debugRebuildSeconds: Int? = ProcessInfo.processInfo.environment["THRU_DEBUG_REBUILD_AFTER"].flatMap { Int($0) }.map { min(max($0, 0), 3600) }

    private let stallTicks = 5          // 500 ms without an audio callback
    private let badLayoutTicks = 30     // 3 s of wrong layout with both devices present
    private let holdoffTicks = 20       // 2 s of healthy audio before unmuting after a loss (the clock device returns late)

    private var timer: DispatchSourceTimer?
    private var sigSources: [DispatchSourceSignal] = []
    private var power: PowerWatcher?
    private var ui: MeterUI?

    init(_ cfg: RouteConfig) {
        var c = cfg
        c.buffer = min(512, max(32, c.buffer))
        c.gain = min(1, max(0, c.gain))
        self.cfg = c
    }

    func run() -> Never {
        for s in [SIGINT, SIGTERM] {
            signal(s, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: s, queue: .main)
            src.setEventHandler { [weak self] in self?.stop() }
            src.resume()
            sigSources.append(src)
        }
        if cfg.meter && Term.isInteractive {
            let u = MeterUI(engine: { [weak self] in self?.engine }, quit: { [weak self] in self?.stop() },
                            route: "\(cfg.inputText) → \(cfg.outputText)")
            u.start()
            ui = u
            eventSink = { [weak u] line in u?.addEvent(line) }
        }
        power = PowerWatcher(onSleep: { [weak self] in self?.sleeping() }, onWake: { [weak self] in self?.woke() })
        power?.start()
        attempt()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        dispatchMain()
    }

    private func stop() {
        eventSink = nil
        ui?.shutdown()   // restore the terminal before the final line is printed
        engine?.teardown()
        say("stopped")
        exit(0)
    }

    private func sleeping() {
        guard !asleep else { return }
        asleep = true
        ui?.setState("asleep")
        sleptWall = Date().timeIntervalSince1970
        sleptUp = DispatchTime.now().uptimeNanoseconds
        engine?.teardown()
        engine = nil
        say("sleeping")
    }

    private func woke() {
        guard asleep else { return }
        asleep = false
        announcedWaiting = []
        present = [:]
        rateComplaint = ""
        lastFailure = ""
        ui?.setState("waiting")
        say("woke")
    }

    private func rebuild(_ reason: String) {
        ui?.setState("rebuilding")
        say("rebuilding (\(reason))")
        engine?.teardown()
        engine = nil
        announcedWaiting = []
        present = [:]
    }

    private func tick() {
        ticks += 1
        if asleep {
            // If the wake message is ever missed, wall time keeps running while uptime paused: that gap proves we slept.
            let wall = Date().timeIntervalSince1970 - sleptWall
            let up = Double(DispatchTime.now().uptimeNanoseconds - sleptUp) / 1e9
            if wall - up > 2 { woke() }
            return
        }
        guard let engine = engine, let inDev = input, let outDev = output else {
            if ticks % 5 == 0 { attempt() }
            return
        }

        // Device presence drives lost/restored lines; the audio callback independently mutes on a bad layout.
        if ticks % 2 == 0 {
            let now = Set(CA.allDevices().map { $0.uid })
            for d in [inDev, outDev] where !now.isEmpty {   // an empty list means the enumeration failed, not that both left
                let p = now.contains(d.uid)
                if present[d.uid, default: true] != p {
                    present[d.uid] = p
                    say(p ? "restored \(d.name)" : "lost \(d.name)")
                }
            }
            orderOK = CA.activeSubUIDs(engine.aggID) == [inDev.uid, outDev.uid]
        }
        let bothPresent = present.values.allSatisfy { $0 }

        // Health: callback alive, layout right, sub-devices in the order the callback assumes.
        let c = engine.calls
        stalled = (c == lastCalls && bothPresent) ? stalled + 1 : 0
        lastCalls = c
        let faultCount = engine.faults
        let faulted = faultCount != lastFaults   // a blip between two ticks still restarts the holdoff
        lastFaults = faultCount
        let healthy = engine.layoutValid && orderOK && !faulted
        badTicks = (healthy || !bothPresent) ? 0 : badTicks + 1
        goodTicks = healthy ? goodTicks + 1 : 0

        if stalled >= stallTicks && ticks - connectedTick >= 20 { return rebuild("audio stalled") }
        // Repeated layout rebuilds back off (3 s, 6, 12, 24, 48) so a persistent mismatch can't flap.
        if badTicks >= badLayoutTicks << min(layoutRebuilds, 4) && bothPresent {
            layoutRebuilds += 1
            return rebuild("layout did not recover")
        }
        if let at = debugRebuildTick, ticks >= at { debugRebuildTick = nil; return rebuild("debug") }

        // Mute on any trouble; unmute (with a fade) only after 2 s of continuous health.
        if !healthy && !muted {
            engine.setAllow(false)
            muted = true
            ui?.setState("muted")
        } else if healthy && muted && goodTicks >= holdoffTicks {
            engine.setAllow(true)
            muted = false
            ui?.setState("connected")
            layoutRebuilds = 0
            say("unmuted")
        }

        if cfg.meter && ui == nil && ticks % 10 == 0 {
            let p = engine.takePeaks()
            say(String(format: "meter in=%.4f out=%.4f", p.input, p.output))
        }
    }

    private func resolve(_ text: String, needInput: Bool, devices: [AudioDevice]) -> AudioDevice? {
        // A user alias stands in for its device specifier; output lines still show the real device name.
        let viaAlias = Aliases.lookup(text)
        let specifier = viaAlias?.device ?? text
        let shown = viaAlias == nil ? "'\(text)'" : "'\(specifier)' (alias '\(text)')"
        switch CA.resolve(specifier, needInput: needInput, in: devices) {
        case .found(let d):
            if announcedWaiting.remove(text) != nil { say("found '\(d.name)'") }
            return d
        case .ambiguous(let list):
            let msg = "\(shown) matches several devices: \(list.map { "'\($0.name)'" }.joined(separator: ", ")). Use a longer name or the UID."
            if !everConnected { fail(msg, code: 2) }
            if msg != lastFailure { lastFailure = msg; FileHandle.standardError.write(Data("thru: \(msg)\n".utf8)) }
            return nil
        case .none:
            if cfg.noWait && !everConnected { fail("no \(needInput ? "input" : "output") device matches \(shown)", code: 2) }
            ui?.setState("waiting")
            if announcedWaiting.insert(text).inserted { say("waiting for '\(text)'") }
            return nil
        }
    }

    /// With no --map: prefer the input's processed pair when the driver names it ("Wet Signal L" on a Quad Cortex),
    /// otherwise the first stereo pair.
    private func defaultSpec(_ i: AudioDevice, _ o: AudioDevice) -> String {
        let names = CA.channelNames(i.id, kAudioObjectPropertyScopeInput, count: i.inputs)
        if o.outputs >= 2, let k = names.firstIndex(where: { $0.lowercased().contains("wet") }), k + 1 < i.inputs {
            return "\(k + 1)-\(k + 2):1-2"
        }
        return defaultChannelMapSpec(inputChannels: i.inputs, outputChannels: o.outputs)
    }

    private func attempt() {
        let devices = CA.allDevices()
        let inDev = resolve(cfg.inputText, needInput: true, devices: devices)
        let outDev = resolve(cfg.outputText, needInput: false, devices: devices)
        guard let i = inDev, let o = outDev else { return }

        // Don't change the rate of a device other apps may be using; wait and say why.
        guard i.rate == o.rate else {
            let msg = "sample rates differ (\(i.name) \(Int(i.rate)) Hz, \(o.name) \(Int(o.rate)) Hz); not changing device rates"
            if cfg.noWait && !everConnected { fail(msg, code: 4) }
            if msg != rateComplaint { rateComplaint = msg; say(msg) }
            return
        }

        let map: ChannelMap
        do {
            map = try parseChannelMap(cfg.map ?? pinnedSpec ?? Aliases.mapSpec(input: Aliases.lookup(cfg.inputText), output: Aliases.lookup(cfg.outputText)) ?? defaultSpec(i, o), inputChannels: i.inputs, outputChannels: o.outputs)
        } catch let e as MapError {
            if !everConnected { fail("bad map: \(e.message)", code: 3) }
            let msg = "could not connect: bad map: \(e.message); retrying"
            if msg != lastFailure { lastFailure = msg; say(msg) }
            return
        } catch { fail("bad map", code: 3) }

        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let started = mach_absolute_time()
        do {
            // The very first connect plays at once; any later connect (after a rebuild or wake) holds muted until audio is steady.
            let e = try Engine(input: i, output: o, map: map, buffer: UInt32(cfg.buffer), gain: cfg.gain, allow: !everConnected)
            let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
            while e.firstCallTicks == 0 && DispatchTime.now().uptimeNanoseconds < deadline { usleep(500) }
            guard e.firstCallTicks != 0 else {
                e.teardown()
                throw EngineError(message: "audio callback never started")
            }
            engine = e
            input = i
            output = o
            present = [i.uid: true, o.uid: true]
            muted = everConnected
            stalled = 0; badTicks = 0; goodTicks = 0; lastCalls = e.calls; orderOK = true
            lastFaults = e.faults; connectedTick = ticks
            if !everConnected, let s = debugRebuildSeconds { debugRebuildTick = ticks + s * 10 }
            everConnected = true
            buildFailures = 0
            lastFailure = ""
            let ms = Int(Double(e.firstCallTicks &- started) * Double(tb.numer) / Double(tb.denom) / 1_000_000)
            ui?.connected(route: "\(i.name) → \(o.name)",
                          detail: "map \(map.spec)   \(cfg.buffer) frames   gain \(String(format: "%.2f", cfg.gain))",
                          outChannels: map.pairs.map { $0.output }, inChannels: map.pairs.map { $0.input })
            ui?.setState(muted ? "muted" : "connected")
            say("connected \(i.name) -> \(o.name) map=\(map.spec) buffer=\(cfg.buffer) first-audio=\(ms)ms")
            if pinnedSpec == nil {   // save once: a rebuild must never overwrite the route with a re-guessed map
                pinnedSpec = map.spec
                var saved = cfg
                saved.map = map.spec
                SavedRoute.save(saved)
            }
        } catch let e as EngineError {
            buildFailures += 1
            // Before the first connect, give up after three tries. After that, never exit: keep retrying.
            if !everConnected && (buildFailures >= 3 || cfg.noWait) { fail(e.message, code: 4) }
            if e.message != lastFailure { lastFailure = e.message; say("could not connect: \(e.message); retrying") }
        } catch {
            fail("\(error)", code: 4)
        }
    }
}
