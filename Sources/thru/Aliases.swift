import Foundation

struct DeviceAlias: Codable, Equatable {
    var device: String
    var channels: String?
}

/// User-managed short names for device specifiers, stored in ~/.config/thru/aliases.json (names lowercase).
enum Aliases {
    static let reservedNames: Set<String> = ["list", "inspect", "map-check", "alias", "help", "version"]

    static var url: URL {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent(".config/thru/aliases.json")
    }

    static func load() -> [String: DeviceAlias] {
        guard let data = try? Data(contentsOf: url),
              let all = try? JSONDecoder().decode([String: DeviceAlias].self, from: data) else { return [:] }
        return all
    }

    static func save(_ all: [String: DeviceAlias]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(all).write(to: url, options: .atomic)
    }

    static func lookup(_ name: String) -> DeviceAlias? { load()[name.lowercased()] }

    /// nil when the name is acceptable, otherwise the reason.
    static func nameProblem(_ name: String) -> String? {
        if name.isEmpty { return "name is empty" }
        if name.hasPrefix("-") { return "name must not start with '-'" }
        if reservedNames.contains(name.lowercased()) { return "'\(name)' is a command word" }
        let ok = name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) }
        return ok ? nil : "use letters, digits, '.', '_' and '-' only"
    }

    /// The map implied by the aliases' channel sides, or nil when neither alias names channels.
    static func mapSpec(input: DeviceAlias?, output: DeviceAlias?) -> String? {
        switch (input?.channels, output?.channels) {
        case let (a?, b?):
            return "\(a):\(b)"
        case let (a?, nil):
            guard let n = try? channelSideCount(a), n > 0 else { return nil }
            return "\(a):1-\(n)"
        case let (nil, b?):
            guard let n = try? channelSideCount(b), n > 0 else { return nil }
            return "1-\(n):\(b)"
        default:
            return nil
        }
    }
}
