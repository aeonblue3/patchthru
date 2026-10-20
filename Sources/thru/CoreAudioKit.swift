import CoreAudio
import Foundation

struct AudioDevice {
    let id: AudioObjectID
    let name: String
    let uid: String
    let inputs: Int
    let outputs: Int
    let rate: Double
    let bufferFrames: Int
    let alive: Bool
    let aggregate: Bool
}

enum Resolution {
    case found(AudioDevice)
    case none
    case ambiguous([AudioDevice])
}

enum CA {
    static func address(_ sel: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func deviceIDs() -> [AudioObjectID] {
        var a = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == 0, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == 0 else { return [] }
        return ids
    }

    static func string(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var a = address(sel)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &ref) == 0, let r = ref else { return nil }
        return r.takeRetainedValue() as String
    }

    static func u32(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector,
                    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var a = address(sel, scope)
        var v: UInt32 = 0
        var size = UInt32(4)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == 0 else { return nil }
        return v
    }

    static func f64(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> Double? {
        var a = address(sel)
        var v: Float64 = 0
        var size = UInt32(8)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == 0 else { return nil }
        return v
    }

    /// Channels per buffer (stream) for one direction. One entry per stream.
    static func streamBuffers(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> [Int] {
        var a = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == 0, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == 0 else { return [] }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }

    static func allDevices() -> [AudioDevice] {
        deviceIDs().compactMap { id in
            guard let name = string(id, kAudioObjectPropertyName),
                  let uid = string(id, kAudioDevicePropertyDeviceUID),
                  !name.hasPrefix("thru-") else { return nil }
            return AudioDevice(
                id: id, name: name, uid: uid,
                inputs: streamBuffers(id, kAudioObjectPropertyScopeInput).reduce(0, +),
                outputs: streamBuffers(id, kAudioObjectPropertyScopeOutput).reduce(0, +),
                rate: f64(id, kAudioDevicePropertyNominalSampleRate) ?? 0,
                bufferFrames: Int(u32(id, kAudioDevicePropertyBufferFrameSize) ?? 0),
                alive: (u32(id, kAudioDevicePropertyDeviceIsAlive) ?? 0) != 0,
                aggregate: u32(id, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeAggregate)
        }
    }

    /// Exact UID, then exact name, then case-insensitive substring. Several substring matches are ambiguous.
    static func resolve(_ text: String, needInput: Bool, in devices: [AudioDevice], allowAggregates: Bool = false) -> Resolution {
        // User aggregates (like "Studio") are never route endpoints: nesting an aggregate in ours is unsupported.
        let usable = devices.filter { (allowAggregates || !$0.aggregate) && (needInput ? $0.inputs > 0 : $0.outputs > 0) }
        if let d = usable.first(where: { $0.uid == text }) { return .found(d) }
        let lower = text.lowercased()
        let exact = usable.filter { $0.name.lowercased() == lower }
        if exact.count == 1 { return .found(exact[0]) }
        let matches = usable.filter { $0.name.lowercased().contains(lower) }
        switch matches.count {
        case 0: return .none
        case 1: return .found(matches[0])
        default: return .ambiguous(matches)
        }
    }

    /// Driver-reported channel names for one direction (1-based element order), "" when the driver gives none.
    static func channelNames(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope, count: Int) -> [String] {
        (0..<count).map { i in
            var a = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyElementName, mScope: scope,
                                               mElement: AudioObjectPropertyElement(i + 1))
            var ref: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &ref) == 0, let r = ref else { return "" }
            return r.takeRetainedValue() as String
        }
    }

    /// UIDs of the aggregate's currently active sub-devices, in stream order.
    static func activeSubUIDs(_ agg: AudioObjectID) -> [String] {
        var a = address(kAudioAggregateDevicePropertyActiveSubDeviceList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(agg, &a, 0, nil, &size) == 0, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(agg, &a, 0, nil, &size, &ids) == 0 else { return [] }
        return ids.compactMap { string($0, kAudioDevicePropertyDeviceUID) }
    }

    static func composition(_ id: AudioObjectID) -> [String: Any]? {
        var a = address(kAudioAggregateDevicePropertyComposition)
        var ref: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &ref) == 0, let r = ref else { return nil }
        return r.takeRetainedValue() as? [String: Any]
    }
}
