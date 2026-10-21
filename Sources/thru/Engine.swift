import CoreAudio
import Darwin
import Foundation

/// State shared with the audio thread. Plain memory, allocated once; the callback never allocates or locks.
struct RTState {
    var calls: UInt64 = 0
    var firstCallTicks: UInt64 = 0
    var valid: Int32 = 0
    var faults: UInt32 = 0   // counts every invalid cycle, so a blip shorter than one supervisor tick is still seen
    var allow: Int32 = 1   // 0 = hold output muted (set by the main queue after a loss, until audio is trustworthy again)
    var inPeaks: UnsafeMutablePointer<Float>    // per mapped pair, since the last takeChannelPeaks()
    var outPeaks: UnsafeMutablePointer<Float>
    var inSq: UnsafeMutablePointer<Float>       // running sum of squares per mapped pair, for RMS
    var outSq: UnsafeMutablePointer<Float>
    var sqFrames: UInt64 = 0                    // frames accumulated into the sums above
    var gainCur: Float = 0
    var rampStep: Float = 0
    var master: Float = 1
    var pairCount: Int = 0
    var inCh: UnsafeMutablePointer<Int>
    var outCh: UnsafeMutablePointer<Int>
    var wantIn: Int = 0
    var wantOut: Int = 0
    var expIn: Int = 0
    var expOut: Int = 0
    var outBufIdx: Int = 0
    var bufOffset: Int = 8   // offsetof(AudioBufferList, mBuffers); set from MemoryLayout at init
}

struct EngineError: Error { let message: String }

/// The IOProc. C calling convention with the state passed as client data, so the compiled body makes no Swift runtime
/// calls (no retain/release, no metadata lookups). A vanished sub-device does not stop this callback: it keeps firing
/// with fewer or empty buffers, so every cycle validates the full layout and stays silent on any mismatch.
private let thruIOProc: AudioDeviceIOProc = { _, _, inData, _, outData, _, client in
    guard let client = client else { return noErr }
    let s = client.assumingMemoryBound(to: RTState.self)
    let off = s.pointee.bufOffset
    let nOut = Int(outData.pointee.mNumberBuffers)
    let ob = (UnsafeMutableRawPointer(outData) + off).assumingMemoryBound(to: AudioBuffer.self)
    for b in 0..<nOut { if let p = ob[b].mData { memset(p, 0, Int(ob[b].mDataByteSize)) } }
    if s.pointee.firstCallTicks == 0 { s.pointee.firstCallTicks = mach_absolute_time() }
    s.pointee.calls &+= 1

    let nIn = Int(inData.pointee.mNumberBuffers)
    let ib = (UnsafeRawPointer(inData) + off).assumingMemoryBound(to: AudioBuffer.self)
    let wantIn = s.pointee.wantIn, wantOut = s.pointee.wantOut, oi = s.pointee.outBufIdx
    guard nIn == s.pointee.expIn, nOut == s.pointee.expOut,
          Int(ib[0].mNumberChannels) == wantIn, Int(ob[oi].mNumberChannels) == wantOut,
          let ip = ib[0].mData?.assumingMemoryBound(to: Float.self),
          let op = ob[oi].mData?.assumingMemoryBound(to: Float.self)
    else { s.pointee.valid = 0; s.pointee.gainCur = 0; s.pointee.faults &+= 1; return noErr }
    let frames = Int(ib[0].mDataByteSize) / (4 * wantIn)
    guard frames > 0, Int(ob[oi].mDataByteSize) == frames * 4 * wantOut
    else { s.pointee.valid = 0; s.pointee.gainCur = 0; s.pointee.faults &+= 1; return noErr }
    s.pointee.valid = 1
    guard s.pointee.allow != 0 else { s.pointee.gainCur = 0; return noErr }

    var g = s.pointee.gainCur
    let step = s.pointee.rampStep, master = s.pointee.master
    let n = s.pointee.pairCount
    let inCh = s.pointee.inCh, outCh = s.pointee.outCh
    let inPeaks = s.pointee.inPeaks, outPeaks = s.pointee.outPeaks
    let inSq = s.pointee.inSq, outSq = s.pointee.outSq
    for f in 0..<frames {
        if g < 1 { g = min(1, g + step) }
        let gg = g * master
        for k in 0..<n {
            let x = ip[f * wantIn + inCh[k]]
            let y = x * gg
            op[f * wantOut + outCh[k]] = y
            let ax = abs(x), ay = abs(y)
            if ax > inPeaks[k] { inPeaks[k] = ax }
            if ay > outPeaks[k] { outPeaks[k] = ay }
            inSq[k] += x * x
            outSq[k] += y * y
        }
    }
    s.pointee.gainCur = g
    s.pointee.sqFrames &+= UInt64(frames)
    return noErr
}

/// One private aggregate [input device (drift-compensated), output device (clock)] and one IOProc that copies mapped channels.
final class Engine {
    private(set) var aggID = AudioObjectID(0)
    private var proc: AudioDeviceIOProcID?
    private let rt: UnsafeMutablePointer<RTState>
    private var running = false
    private var freed = false

    var calls: UInt64 { rt.pointee.calls }
    var firstCallTicks: UInt64 { rt.pointee.firstCallTicks }
    var layoutValid: Bool { rt.pointee.valid != 0 }
    var faults: UInt32 { rt.pointee.faults }

    /// Mute (false) or release (true) the output. Releasing restarts the ~50 ms fade-in from silence.
    func setAllow(_ on: Bool) { rt.pointee.allow = on ? 1 : 0 }

    /// Levels of the mapped channels since the last call: linear peaks, and mean squares for RMS.
    /// Racy by design: a sample landing during the reset can be lost, which only matters for a meter.
    struct Levels {
        var inPeaks: [Float]
        var outPeaks: [Float]
        var inMeanSq: [Float]
        var outMeanSq: [Float]
        var frames: UInt64
    }

    func takeLevels() -> Levels {
        let n = rt.pointee.pairCount
        let frames = rt.pointee.sqFrames
        let div = Float(max(1, frames))
        let l = Levels(
            inPeaks: (0..<n).map { rt.pointee.inPeaks[$0] },
            outPeaks: (0..<n).map { rt.pointee.outPeaks[$0] },
            inMeanSq: (0..<n).map { rt.pointee.inSq[$0] / div },
            outMeanSq: (0..<n).map { rt.pointee.outSq[$0] / div },
            frames: frames)
        rt.pointee.inPeaks.update(repeating: 0, count: n)
        rt.pointee.outPeaks.update(repeating: 0, count: n)
        rt.pointee.inSq.update(repeating: 0, count: n)
        rt.pointee.outSq.update(repeating: 0, count: n)
        rt.pointee.sqFrames = 0
        return l
    }

    /// Largest input and output peak across channels since the last call (for the one-line meter).
    func takePeaks() -> (input: Float, output: Float) {
        let l = takeLevels()
        return (l.inPeaks.max() ?? 0, l.outPeaks.max() ?? 0)
    }

    init(input: AudioDevice, output: AudioDevice, map: ChannelMap, buffer: UInt32, gain: Float, allow: Bool = true) throws {
        guard input.uid != output.uid else { throw EngineError(message: "input and output are the same device; not supported yet") }
        let inBufs = CA.streamBuffers(input.id, kAudioObjectPropertyScopeInput)
        let outBufs = CA.streamBuffers(output.id, kAudioObjectPropertyScopeOutput)
        guard inBufs.count == 1, outBufs.count == 1 else {
            throw EngineError(message: "multi-stream devices are not supported yet (\(input.name): \(inBufs.count) in, \(output.name): \(outBufs.count) out)")
        }
        let wantIn = inBufs[0], wantOut = outBufs[0]
        guard wantIn > 0, wantOut > 0, !map.pairs.isEmpty,
              map.pairs.allSatisfy({ $0.input < wantIn && $0.output < wantOut })
        else { throw EngineError(message: "channel map does not fit the devices' buffers") }

        // Aggregate buffer order follows sub-device order [input, output]; other directions of each device add buffers.
        let expIn = 1 + CA.streamBuffers(output.id, kAudioObjectPropertyScopeInput).count
        let outBufIdx = CA.streamBuffers(input.id, kAudioObjectPropertyScopeOutput).count
        let expOut = outBufIdx + 1

        let n = map.pairs.count
        let inCh = UnsafeMutablePointer<Int>.allocate(capacity: n)
        let outCh = UnsafeMutablePointer<Int>.allocate(capacity: n)
        for (i, p) in map.pairs.enumerated() { inCh[i] = p.input; outCh[i] = p.output }
        let inPeaks = UnsafeMutablePointer<Float>.allocate(capacity: n)
        let outPeaks = UnsafeMutablePointer<Float>.allocate(capacity: n)
        inPeaks.initialize(repeating: 0, count: n)
        outPeaks.initialize(repeating: 0, count: n)
        let inSq = UnsafeMutablePointer<Float>.allocate(capacity: n)
        let outSq = UnsafeMutablePointer<Float>.allocate(capacity: n)
        inSq.initialize(repeating: 0, count: n)
        outSq.initialize(repeating: 0, count: n)
        rt = UnsafeMutablePointer<RTState>.allocate(capacity: 1)
        rt.initialize(to: RTState(inPeaks: inPeaks, outPeaks: outPeaks, inSq: inSq, outSq: outSq, inCh: inCh, outCh: outCh))
        rt.pointee.pairCount = n
        rt.pointee.wantIn = wantIn
        rt.pointee.wantOut = wantOut
        rt.pointee.expIn = expIn
        rt.pointee.expOut = expOut
        rt.pointee.outBufIdx = outBufIdx
        rt.pointee.master = gain
        rt.pointee.allow = allow ? 1 : 0
        rt.pointee.rampStep = Float(1.0 / (0.05 * max(output.rate, 8000)))   // ~50 ms fade-in
        rt.pointee.bufOffset = MemoryLayout<AudioBufferList>.offset(of: \AudioBufferList.mBuffers) ?? 8

        do { try build(input: input, output: output, buffer: buffer) } catch {
            teardown()
            throw error
        }
    }

    private func build(input: AudioDevice, output: AudioDevice, buffer: UInt32) throws {
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "thru-\(getpid())",
            kAudioAggregateDeviceUIDKey: "io.github.aeonblue3.patchthru.\(getpid()).\(DispatchTime.now().uptimeNanoseconds)",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceMainSubDeviceKey: output.uid,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: input.uid, kAudioSubDeviceDriftCompensationKey: 1],
                [kAudioSubDeviceUIDKey: output.uid, kAudioSubDeviceDriftCompensationKey: 0],
            ],
        ]
        var status = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &aggID)
        guard status == 0 else { throw EngineError(message: "could not create aggregate device (CoreAudio status \(status))") }

        var sizeAddr = CA.address(kAudioDevicePropertyBufferFrameSize)
        var frames = buffer
        status = AudioObjectSetPropertyData(aggID, &sizeAddr, 0, nil, 4, &frames)
        guard status == 0 else { throw EngineError(message: "could not set buffer size \(buffer) (CoreAudio status \(status))") }

        status = AudioDeviceCreateIOProcID(aggID, thruIOProc, UnsafeMutableRawPointer(rt), &proc)
        guard status == 0 else { throw EngineError(message: "could not create IO proc (CoreAudio status \(status))") }
        status = AudioDeviceStart(aggID, proc)
        guard status == 0 else { throw EngineError(message: "could not start audio (CoreAudio status \(status))") }
        running = true
    }

    /// Order matters: stop IO, destroy the IOProc, destroy the aggregate, and only then free the memory the callback used.
    /// The Engine must not be read after this returns.
    func teardown() {
        if aggID != 0 {
            if running { AudioDeviceStop(aggID, proc) }
            if let p = proc { AudioDeviceDestroyIOProcID(aggID, p) }
            AudioHardwareDestroyAggregateDevice(aggID)
            aggID = 0
        }
        running = false
        proc = nil
        if !freed {
            rt.pointee.inCh.deallocate()
            rt.pointee.outCh.deallocate()
            rt.pointee.inPeaks.deallocate()
            rt.pointee.outPeaks.deallocate()
            rt.pointee.inSq.deallocate()
            rt.pointee.outSq.deallocate()
            rt.deinitialize(count: 1)
            rt.deallocate()
            freed = true
        }
    }
}
