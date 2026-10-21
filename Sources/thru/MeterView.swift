import Foundation

/// Everything the meter draws, as plain values. See docs/specs/meter-spec.md.
struct MeterFrame {
    var route: String = ""
    var detail: String = ""
    var outLabels: [String] = []
    var outDB: [Double] = []
    var outHoldDB: [Double] = []
    var outClip: [Bool] = []
    var inLabels: [String] = []
    var inDB: [Double] = []
    var inHoldDB: [Double] = []
    var outRMSDB: [Double] = []      // empty = no RMS data: peak-only rows
    var inRMSDB: [Double] = []
    var showRMS: Bool = false
    var showInputs: Bool = false
    var state: String = ""
    var events: [String] = []
    var color: Bool = false
}

private let meterFloorDB = -60.0
private let labelColumn = 9      // " " + 7-wide label + " "
private let readoutColumn = 21
private let clipColumn = 6

private func fit(_ s: String, _ w: Int) -> String { String(s.prefix(max(0, w))) }
private func padRight(_ s: String, _ n: Int) -> String { s.count >= n ? fit(s, n) : s + String(repeating: " ", count: n - s.count) }
private func padLeft(_ s: String, _ n: Int) -> String { s.count >= n ? fit(s, n) : String(repeating: " ", count: n - s.count) + s }
private func fraction(_ db: Double) -> Double { (min(0, max(meterFloorDB, db)) - meterFloorDB) / -meterFloorDB }
private func dbText(_ db: Double) -> String { db <= meterFloorDB ? "-inf" : String(format: "%.1f", db) }

private func paint(_ text: String, _ code: String?, _ on: Bool) -> String {
    guard on, let code = code, !text.isEmpty else { return text }
    return "\u{1B}[\(code)m\(text)\u{1B}[0m"
}

/// Plain text is cut to the width first, then each piece is styled, so colors never change the layout.
private func styledLine(_ segments: [(String, String?)], width: Int, color: Bool) -> String {
    var remaining = width
    var out = ""
    for (text, code) in segments {
        guard remaining > 0 else { break }
        let piece = fit(text, remaining)
        out += paint(piece, code, color)
        remaining -= piece.count
    }
    return out
}

/// Same thresholds as the bar cells, so a number and its bar agree. Silence is faint.
private func levelCode(_ db: Double) -> String {
    db <= meterFloorDB ? "2" : (db < -18 ? "32" : (db <= -6 ? "33" : "31"))
}

private func stateCode(_ state: String) -> String? {
    switch state {
    case "connected": return "1;32"
    case "muted", "waiting": return "1;33"
    case "rebuilding": return "1;35"
    case "asleep": return "1;36"
    default: return nil
    }
}

private func eventCode(_ message: String) -> String? {
    let m = message.lowercased()
    if m.contains("lost") || m.contains("could not") || m.contains("differ") { return "31" }
    if m.contains("waiting") || m.contains("rebuilding") || m.contains("sleeping") { return "33" }
    if m.contains("restored") || m.contains("unmuted") || m.contains("connected") || m.contains("woke") || m.contains("found") { return "32" }
    return nil
}

private func eventLine(_ event: String, width: Int, color: Bool) -> String {
    // Events arrive as "HH:mm:ss message"; the timestamp is faint and the message is colored by meaning.
    if event.count > 9, event[event.index(event.startIndex, offsetBy: 2)] == ":" {
        let stamp = String(event.prefix(8)), message = String(event.dropFirst(9))
        return styledLine([("  ", nil), (stamp, "2"), (" ", nil), (message, eventCode(message))], width: width, color: color)
    }
    return styledLine([("  ", nil), (event, eventCode(event))], width: width, color: color)
}

/// Green below -18 dB, yellow up to -6 dB, red above, by the cell's own level.
private func cellColor(_ index: Int, of cells: Int) -> String {
    let top = meterFloorDB + Double(index + 1) / Double(cells) * -meterFloorDB
    return top < -18 ? "32" : (top <= -6 ? "33" : "31")
}

private func meterRow(label: String, db: Double, hold: Double, rms: Double?, clip: Bool, isInput: Bool, cells: Int, color: Bool) -> String {
    let filled = Int((fraction(db) * Double(cells)).rounded())
    let rmsFilled = rms.map { Int((fraction($0) * Double(cells)).rounded()) }
    let holdCell: Int? = hold > meterFloorDB ? min(cells - 1, max(0, Int((fraction(hold) * Double(cells)).rounded()) - 1)) : nil
    var bar = ""
    for i in 0..<cells {
        // With RMS: solid up to the RMS level, medium shade up to the peak level, light beyond.
        let solid = rmsFilled.map { i < $0 } ?? (i < filled)
        let body = i < filled || solid
        let glyph = i == holdCell ? "┃" : (solid ? "█" : (i < filled ? (rmsFilled == nil ? "█" : "▒") : "░"))
        if color && (body || i == holdCell) {
            bar += "\u{1B}[\(cellColor(i, of: cells))m\(glyph)\u{1B}[0m"
        } else {
            bar += glyph
        }
    }
    // 21 columns: space + 6-wide level + " dB" + " hold " + 5-wide hold level. Numbers take the color of their level.
    let readout: String
    if let r = rms {   // peak and RMS, still 21 columns; the hold tick on the bar replaces the hold number
        readout = " " + paint(padLeft(dbText(db), 6), levelCode(db), color) + paint(" dB", "2", color)
            + paint("  rms ", "2", color) + paint(padLeft(dbText(r), 5), levelCode(r), color)
    } else {
        readout = " " + paint(padLeft(dbText(db), 6), levelCode(db), color) + paint(" dB", "2", color)
            + paint(" hold ", "2", color) + paint(padLeft(dbText(hold), 5), levelCode(hold), color)
    }
    let clipText = clip ? (color ? "\u{1B}[1;97;41m CLIP \u{1B}[0m" : " CLIP ") : String(repeating: " ", count: clipColumn)
    return " " + paint(padRight(label, 7), isInput ? "2" : "1", color) + " " + bar + readout + clipText
}

private func rmsFor(_ on: Bool, _ values: [Double], _ i: Int) -> Double? { on && i < values.count ? values[i] : nil }

private func scaleRow(width: Int, cells: Int) -> String {
    var chars = Array(repeating: Character(" "), count: width)
    var lastEnd = -2
    for tick in [-60.0, -48, -36, -24, -12, -6, 0] {
        let label = tick == 0 ? "0" : String(Int(tick))
        let end = labelColumn + Int((fraction(tick) * Double(cells)).rounded()) - 1   // column of the label's last character
        let start = end - label.count + 1
        guard start >= 0, end < width, start > lastEnd + 1 else { continue }
        for (j, c) in label.enumerated() { chars[start + j] = c }
        lastEnd = end
    }
    return String(chars)
}

func renderMeter(_ f: MeterFrame, width: Int, height: Int) -> [String] {
    guard width >= 50, height >= 10 else { return ["terminal too small (need 50x10)"] }
    let cells = width - labelColumn - readoutColumn - clipColumn
    let rule = paint(String(repeating: "─", count: width), "2", f.color)
    let outs = min(f.outLabels.count, f.outDB.count, f.outHoldDB.count)
    let ins = f.showInputs ? min(f.inLabels.count, f.inDB.count, f.inHoldDB.count) : 0

    let header = styledLine([(" ", nil), ("patchthru", "1;36"), ("   ", nil), (f.route, "1"), ("    ", nil), (f.detail, "36")], width: width, color: f.color)
    var inputRows = (0..<ins).map {
        meterRow(label: f.inLabels[$0], db: f.inDB[$0], hold: f.inHoldDB[$0], rms: rmsFor(f.showRMS, f.inRMSDB, $0), clip: false, isInput: true, cells: cells, color: f.color)
    }
    let outputRows = (0..<outs).map {
        meterRow(label: f.outLabels[$0], db: f.outDB[$0], hold: f.outHoldDB[$0], rms: rmsFor(f.showRMS, f.outRMSDB, $0),
                 clip: $0 < f.outClip.count ? f.outClip[$0] : false, isInput: false, cells: cells, color: f.color)
    }
    var scale: String? = paint(scaleRow(width: width, cells: cells), "2", f.color)
    var events = f.events.suffix(3).map { eventLine($0, width: width, color: f.color) }
    let key = "1;30;46"   // bold black on cyan: the key itself, layout unchanged
    var help: String? = styledLine([(" ", nil), ("q", key), (" quit   ", nil), ("c", key), (" clear clip   ", nil), ("i", key), (" inputs on/off   ", nil), ("m", key), (" rms on/off", nil)],
                                   width: width, color: f.color)
    let state = styledLine([(" ", nil), (f.state, stateCode(f.state))], width: width, color: f.color)

    func total() -> Int {
        2 + inputRows.count + outputRows.count + (scale == nil ? 0 : 1) + 1 + 1 + events.count + (help == nil ? 0 : 1)
    }
    // Make room in the documented order: help, events (oldest first), scale, input rows. Output rows stay.
    if total() > height { help = nil }
    while total() > height && !events.isEmpty { events.removeFirst() }
    if total() > height { scale = nil }
    while total() > height && !inputRows.isEmpty { inputRows.removeLast() }

    var lines = [header, rule] + inputRows + outputRows
    if let s = scale { lines.append(s) }
    lines += [rule, state] + events
    if let h = help { lines.append(h) }
    return Array(lines.prefix(height))
}
