

import Foundation

struct ChannelPair: Equatable { let input: Int; let output: Int }
struct ChannelMap: Equatable { let pairs: [ChannelPair]; let spec: String }
struct MapError: Error { let message: String }

func parseChannelMap(_ spec: String, inputChannels: Int, outputChannels: Int) throws -> ChannelMap {
    let parts = spec.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2 else { throw MapError(message: "missing colon in '\(spec)'") }
    
    func parseSide(_ side: Substring, limit: Int) throws -> [Int] {
        var channels: [Int] = []
        for token in side.split(separator: ",") {
            let t = token.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            if let dash = t.firstIndex(of: "-") {
                let sStr = String(t[..<dash]).trimmingCharacters(in: .whitespaces)
                let eStr = String(t[dash...]).dropFirst().trimmingCharacters(in: .whitespaces)
                guard let s = Int(sStr), let e = Int(eStr) else { throw MapError(message: "non-numeric in '\(t)'") }
                guard s >= 1 else { throw MapError(message: "channel \(s) < 1 in '\(t)'") }
                guard s <= e else { throw MapError(message: "reversed range \(s)-\(e) in '\(t)'") }
                guard e <= limit else { throw MapError(message: "channel \(e) > \(limit) in '\(t)'") }
                channels.append(contentsOf: s...e)
            } else if let ch = Int(t) {
                guard ch >= 1 else { throw MapError(message: "channel \(ch) < 1 in '\(t)'") }
                guard ch <= limit else { throw MapError(message: "channel \(ch) > \(limit)") }
                channels.append(ch)
            } else { throw MapError(message: "non-numeric '\(t)'") }
        }
        return channels
    }
    
    let inRaw = try parseSide(parts[0], limit: inputChannels)
    let outRaw = try parseSide(parts[1], limit: outputChannels)
    
    guard !inRaw.isEmpty, !outRaw.isEmpty else { throw MapError(message: "empty channel list in '\(spec)'") }

    var seenOut: Set<Int> = []
    for c in outRaw {
        guard seenOut.insert(c).inserted else { throw MapError(message: "duplicate output channel \(c)") }
    }
    
    guard inRaw.count == outRaw.count || inRaw.count == 1 else {
        throw MapError(message: "channel count mismatch \(inRaw.count) vs \(outRaw.count)")
    }
    
    var pairs: [ChannelPair] = []
    for i in 0..<outRaw.count {
        let inp = inRaw.count == 1 ? inRaw[0] : inRaw[i]
        pairs.append(ChannelPair(input: inp - 1, output: outRaw[i] - 1))
    }
    
    return ChannelMap(pairs: pairs, spec: String(spec))
}

func defaultChannelMapSpec(inputChannels: Int, outputChannels: Int) -> String {
    if outputChannels == 1 { return "1:1" }
    if inputChannels == 1 { return "1:1-2" }
    return "1-2:1-2"
}

/// Number of channels named by one side of a map ("3-4" is 2), under the same rules as parseChannelMap.
func channelSideCount(_ side: String) throws -> Int {
    try parseChannelMap("\(side):\(side)", inputChannels: 4096, outputChannels: 4096).pairs.count
}
