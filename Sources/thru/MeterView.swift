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

/// Green below -18 dB, yellow up to -6 dB, red above, by the cell's own level.
private func cellColor(_ index: Int, of cells: Int) -> String {
    let top = meterFloorDB + Double(index + 1) / Double(cells) * -meterFloorDB
    return top < -18 ? "32" : (top <= -6 ? "33" : "31")
}

private func meterRow(label: String, db: Double, hold: Double, clip: Bool, cells: Int, color: Bool) -> String {
    let filled = Int((fraction(db) * Double(cells)).rounded())
    let holdCell: Int? = hold > meterFloorDB ? min(cells - 1, max(0, Int((fraction(hold) * Double(cells)).rounded()) - 1)) : nil
    var bar = ""
    for i in 0..<cells {
        let glyph = i == holdCell ? "┃" : (i < filled ? "█" : "░")
        if color && (i < filled || i == holdCell) {
            bar += "\u{1B}[\(cellColor(i, of: cells))m\(glyph)\u{1B}[0m"
        } else {
            bar += glyph
        }
    }
    let readout = " " + padLeft(dbText(db), 6) + " dB" + " hold " + padLeft(dbText(hold), 5)
    let clipText = clip ? (color ? "\u{1B}[31m CLIP \u{1B}[0m" : " CLIP ") : String(repeating: " ", count: clipColumn)
    return " " + padRight(label, 7) + " " + bar + padRight(readout, readoutColumn) + clipText
}

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
    let rule = String(repeating: "─", count: width)
    let outs = min(f.outLabels.count, f.outDB.count, f.outHoldDB.count)
    let ins = f.showInputs ? min(f.inLabels.count, f.inDB.count, f.inHoldDB.count) : 0

    let header = fit(" patchthru   \(f.route)    \(f.detail)", width)
    var inputRows = (0..<ins).map {
        meterRow(label: f.inLabels[$0], db: f.inDB[$0], hold: f.inHoldDB[$0], clip: false, cells: cells, color: f.color)
    }
    let outputRows = (0..<outs).map {
        meterRow(label: f.outLabels[$0], db: f.outDB[$0], hold: f.outHoldDB[$0],
                 clip: $0 < f.outClip.count ? f.outClip[$0] : false, cells: cells, color: f.color)
    }
    var scale: String? = scaleRow(width: width, cells: cells)
    var events = f.events.suffix(3).map { fit("  " + $0, width) }
    var help: String? = fit(" q quit   c clear clip   i inputs on/off", width)
    let state = fit(" " + f.state, width)

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
