import CoreAudio
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

let thruVersion = "0.1.0"

let args = Array(CommandLine.arguments.dropFirst())
var activeRouter: Router?   // pinned for the life of the process: its signal and timer handlers hold it weakly

func usageAndExit(_ code: Int32) -> Never {
    print(usageText)
    exit(code)
}

func listDevices(json: Bool) {
    let devices = CA.allDevices()
    if json {
        let rows: [[String: Any]] = devices.map {
            ["name": $0.name, "uid": $0.uid, "inputs": $0.inputs, "outputs": $0.outputs, "rate": $0.rate,
             "bufferFrames": $0.bufferFrames, "alive": $0.alive, "aggregate": $0.aggregate]
        }
        let data = (try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])) ?? Data("[]".utf8)
        print(String(decoding: data, as: UTF8.self))
        return
    }
    for d in devices {
        print(String(format: "%-28@ in %-3d out %-3d %6.0f Hz  %@", d.name as NSString, d.inputs, d.outputs, d.rate, d.uid as NSString))
    }
}

func inspect(_ text: String) {
    switch CA.resolve(text, needInput: false, in: CA.allDevices(), allowAggregates: true) {
    case .found(let d): printComposition(d)
    case .ambiguous(let l): fail("'\(text)' matches several devices: \(l.map { $0.name }.joined(separator: ", "))", code: 2)
    case .none:
        // Aggregates like "Studio" may have no output channels in odd states; try inputs too.
        if case .found(let d) = CA.resolve(text, needInput: true, in: CA.allDevices(), allowAggregates: true) { printComposition(d) }
        else { fail("no device matches '\(text)'", code: 2) }
    }
}

func printComposition(_ d: AudioDevice) {
    guard d.aggregate, let comp = CA.composition(d.id) else {
        let data = (try? JSONSerialization.data(withJSONObject: ["aggregate": false, "name": d.name], options: [.sortedKeys])) ?? Data("{}".utf8)
        print(String(decoding: data, as: UTF8.self))
        return
    }
    if JSONSerialization.isValidJSONObject(comp),
       let data = try? JSONSerialization.data(withJSONObject: comp, options: [.prettyPrinted, .sortedKeys]) {
        print(String(decoding: data, as: UTF8.self))
    } else {
        print("\(comp)")
    }
}

func mapCheck(_ spec: String, _ inCh: String, _ outCh: String) {
    guard let i = Int(inCh), let o = Int(outCh) else { usageAndExit(1) }
    do {
        let m = try parseChannelMap(spec, inputChannels: i, outputChannels: o)
        let pairs = m.pairs.map { ["input": $0.input + 1, "output": $0.output + 1] }
        let data = try JSONSerialization.data(withJSONObject: ["pairs": pairs], options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    } catch let e as MapError {
        fail("bad map: \(e.message)", code: 3)
    } catch { fail("bad map", code: 3) }
}

func aliasState(_ device: String) -> String {
    let devices = CA.allDevices()
    var ambiguous = false
    for needInput in [true, false] {
        switch CA.resolve(device, needInput: needInput, in: devices) {
        case .found(let d): return "connected: \(d.name)"
        case .ambiguous: ambiguous = true
        case .none: break
        }
    }
    return ambiguous ? "ambiguous" : "not connected"
}

func aliasCommand(_ rest: [String]) {
    var args = rest
    let sub = (args.isEmpty || args[0].hasPrefix("--")) ? "list" : args.removeFirst()
    switch sub {
    case "list":
        let all = Aliases.load()
        let rows = all.keys.sorted().map { name -> (String, DeviceAlias, String) in (name, all[name]!, aliasState(all[name]!.device)) }
        if args.contains("--json") {
            let objs: [[String: Any]] = rows.map { r in
                var o: [String: Any] = ["name": r.0, "device": r.1.device, "state": r.2]
                o["channels"] = r.1.channels ?? NSNull()
                return o
            }
            let data = (try? JSONSerialization.data(withJSONObject: objs, options: [.prettyPrinted, .sortedKeys])) ?? Data("[]".utf8)
            print(String(decoding: data, as: UTF8.self))
        } else if rows.isEmpty {
            say("no aliases")
        } else {
            for r in rows { print("\(r.0) -> \(r.1.device)\(r.1.channels.map { " (channels \($0))" } ?? "") [\(r.2)]") }
        }
    case "add":
        var channels: String?
        var positional: [String] = []
        var k = 0
        while k < args.count {
            if args[k] == "--channels" {
                k += 1
                guard k < args.count else { usageAndExit(1) }
                channels = args[k]
            } else if args[k].hasPrefix("--") { usageAndExit(1) } else { positional.append(args[k]) }
            k += 1
        }
        guard positional.count == 2 else { usageAndExit(1) }
        let name = positional[0].lowercased(), device = positional[1]
        if let problem = Aliases.nameProblem(positional[0]) { fail("bad alias name: \(problem)", code: 1) }
        if device.trimmingCharacters(in: .whitespaces).isEmpty { fail("bad alias name: device is empty", code: 1) }
        if let c = channels {
            do { _ = try channelSideCount(c) }
            catch let e as MapError { fail("bad channels: \(e.message)", code: 3) }
            catch { fail("bad channels", code: 3) }
        }
        var all = Aliases.load()
        let existed = all[name] != nil
        all[name] = DeviceAlias(device: device, channels: channels)
        do { try Aliases.save(all) } catch { fail("could not save aliases: \(error.localizedDescription)", code: 4) }
        let suffix = channels.map { " (channels \($0))" } ?? ""
        say("alias \(name)\(existed ? " updated" : "") -> \(device)\(suffix)")
        if aliasState(device) == "not connected" {
            FileHandle.standardError.write(Data("thru: note: no device currently matches '\(device)'\n".utf8))
        }
    case "rm":
        guard args.count == 1 else { usageAndExit(1) }
        var all = Aliases.load()
        guard all.removeValue(forKey: args[0].lowercased()) != nil else { fail("no alias '\(args[0])'", code: 2) }
        do { try Aliases.save(all) } catch { fail("could not save aliases: \(error.localizedDescription)", code: 4) }
        say("alias \(args[0].lowercased()) removed")
    default:
        usageAndExit(1)
    }
}

/// Testing aid: render one meter frame for synthetic levels.
func meterSnapshot(_ rest: [String]) {
    var args = rest
    guard args.count >= 3, let w = Int(args[0]), let h = Int(args[1]) else { usageAndExit(1) }
    func levels(_ s: String) -> [Double] { s.split(separator: ",").compactMap { Double($0) } }
    let out = levels(args[2])
    args.removeFirst(3)
    var ins: [Double] = []
    var outRMS: [Double] = []
    var inRMS: [Double] = []
    var color = false
    var k = 0
    while k < args.count {
        if args[k] == "--inputs", k + 1 < args.count { ins = levels(args[k + 1]); k += 1 }
        else if args[k] == "--rms", k + 1 < args.count { outRMS = levels(args[k + 1]); k += 1 }
        else if args[k] == "--in-rms", k + 1 < args.count { inRMS = levels(args[k + 1]); k += 1 }
        else if args[k] == "--color" { color = true }
        else { usageAndExit(1) }
        k += 1
    }
    let f = MeterFrame(
        route: "A → B", detail: "map test",
        outLabels: out.indices.map { "OUT \($0 + 1)" }, outDB: out, outHoldDB: out, outClip: out.map { $0 >= 0 },
        inLabels: ins.indices.map { "IN \($0 + 1)" }, inDB: ins, inHoldDB: ins,
        outRMSDB: outRMS, inRMSDB: inRMS, showRMS: !outRMS.isEmpty || !inRMS.isEmpty,
        showInputs: !ins.isEmpty, state: "connected", events: ["12:00:00 test"], color: color)
    print(renderMeter(f, width: w, height: h).joined(separator: "\n"))
}

// ---- dispatch
if let first = args.first {
    switch first {
    case "-h", "--help", "help": usageAndExit(0)
    case "-v", "--version", "version":
        print("thru \(thruVersion) (patchthru)")
        exit(0)
    case "list":
        listDevices(json: args.contains("--json"))
        exit(0)
    case "inspect":
        guard args.count >= 2 else { usageAndExit(1) }
        inspect(args[1])
        exit(0)
    case "meter-snapshot":
        meterSnapshot(Array(args.dropFirst()))
        exit(0)
    case "alias":
        aliasCommand(Array(args.dropFirst()))
        exit(0)
    case "map-check":
        guard args.count == 4 else { usageAndExit(1) }
        mapCheck(args[1], args[2], args[3])
        exit(0)
    default: break
    }
}

if args.isEmpty {
    guard let saved = SavedRoute.load() else { usageAndExit(1) }
    activeRouter = Router(saved)
    activeRouter!.run()
}

var positionals: [String] = []
var mapSpec: String?
var buffer = 64
var gain: Float = 1
var noWait = false
var meter = false
var i = 0
while i < args.count {
    let a = args[i]
    func value() -> String {
        i += 1
        guard i < args.count else { usageAndExit(1) }
        return args[i]
    }
    switch a {
    case "--map": mapSpec = value()
    case "--buffer":
        guard let b = Int(value()) else { usageAndExit(1) }
        buffer = min(512, max(32, b))
    case "--gain":
        guard let g = Float(value()), g >= 0, g <= 1 else { usageAndExit(1) }
        gain = g
    case "--no-wait": noWait = true
    case "--meter": meter = true
    default:
        if a.hasPrefix("--") { usageAndExit(1) }
        positionals.append(a)
    }
    i += 1
}
guard positionals.count == 2 else { usageAndExit(1) }
activeRouter = Router(RouteConfig(inputText: positionals[0], outputText: positionals[1], map: mapSpec, buffer: buffer, gain: gain,
                   noWait: noWait, meter: meter))
activeRouter!.run()
