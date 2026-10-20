import Foundation
import IOKit
import IOKit.pwr_mgt

/// System sleep/wake notifications for a command-line tool (IOKit only, no AppKit). Callbacks run on the main queue.
/// The caller must keep the watcher alive.
final class PowerWatcher {
    // The message constants are function-like macros Swift can't import: iokit_common_msg(n) = 0xE0000000 | n.
    fileprivate static let canSystemSleep: UInt32 = 0xE000_0270
    fileprivate static let systemWillSleep: UInt32 = 0xE000_0280
    fileprivate static let systemHasPoweredOn: UInt32 = 0xE000_0300

    fileprivate let onSleep: () -> Void
    fileprivate let onWake: () -> Void
    fileprivate var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    init(onSleep: @escaping () -> Void, onWake: @escaping () -> Void) {
        self.onSleep = onSleep
        self.onWake = onWake
    }

    func start() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(refcon, &notifyPort, powerCallback, &notifier)
        guard rootPort != 0, let port = notifyPort else {
            FileHandle.standardError.write(Data("thru: could not register for power events\n".utf8))
            return
        }
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
    }
}

private let powerCallback: IOServiceInterestCallback = { refcon, _, messageType, messageArgument in
    guard let refcon = refcon else { return }
    let w = Unmanaged<PowerWatcher>.fromOpaque(refcon).takeUnretainedValue()
    let arg = Int(bitPattern: messageArgument)
    switch UInt32(truncatingIfNeeded: messageType) {
    case PowerWatcher.canSystemSleep:
        IOAllowPowerChange(w.rootPort, arg)
    case PowerWatcher.systemWillSleep:
        w.onSleep()                      // tear down before the system sleeps, then let it go
        IOAllowPowerChange(w.rootPort, arg)
    case PowerWatcher.systemHasPoweredOn:
        w.onWake()
    default:
        break
    }
}
