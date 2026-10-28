// keykeep — keep a cheap USB keyboard alive, and catch the exact moment it drops.
//
//   keykeep poke [--interval 5] [--led | --key <code>] [--log PATH]   keep-alive loop
//   keykeep once                                                      single poke, prints result
//   keykeep watch                                                     log attach/detach events
//   keykeep devices                                                   list HID devices
//   keykeep status                                                    permissions + presence
//   keykeep perms                                                     ask for Input Monitoring access
//
// Two ways to poke a device:
//   --led   send a real HID output report (LED bitmap) over the USB bus, ~0 impact
//   --key   inject a harmless key event (vK 71 = Clear/NumLock) via CGEvent,
//           needs Accessibility permission and never touches the USB bus
import Foundation
import CoreGraphics
import IOKit
import IOKit.hid
import ApplicationServices
#if canImport(AppKit)
import AppKit
#endif

let KB_VID = 0xc0f4          // "Usb KeyBoard"
let KB_PID = 0x06f5

let formatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()

func out(_ s: String) {
    print("\(formatter.string(from: Date())) \(s)")
    fflush(stdout)
}

func hex(_ v: Int) -> String {
    v < 0 ? "0x" + String(UInt32(bitPattern: Int32(truncatingIfNeeded: v)), radix: 16)
          : "0x" + String(v, radix: 16)
}

// MARK: - HID access

func newManager(vid: Int, pid: Int) -> IOHIDManager {
    let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    let match: [String: Any] = [kIOHIDVendorIDKey: vid, kIOHIDProductIDKey: pid]
    IOHIDManagerSetDeviceMatching(m, match as CFDictionary)
    return m
}

func devices(_ m: IOHIDManager) -> [IOHIDDevice] {
    guard let set = IOHIDManagerCopyDevices(m) else { return [] }
    return ((set as NSSet).allObjects).map { $0 as! IOHIDDevice }
}

func intProp(_ d: IOHIDDevice, _ key: String) -> Int? {
    IOHIDDeviceGetProperty(d, key as CFString) as? Int
}

func strProp(_ d: IOHIDDevice, _ key: String) -> String? {
    IOHIDDeviceGetProperty(d, key as CFString) as? String
}

enum PokeResult {
    case ok(String)
    case absent
    case denied(IOReturn)
    case failed(String)
}

enum HIDError: Error {
    case absent
    case denied(IOReturn)
    case failed(String)
}

/// Open a handle to the keyboard, or explain why not.
func acquireKeyboard() -> Result<(dev: IOHIDDevice, manager: IOHIDManager), HIDError> {
    let m = newManager(vid: KB_VID, pid: KB_PID)
    let r = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
    if r != kIOReturnSuccess {
        return .failure(r == kIOReturnNotPermitted ? .denied(r) : .failed(hex(Int(r))))
    }
    guard let dev = devices(m).first else {
        IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
        return .failure(.absent)
    }
    return .success((dev, m))
}

/// Real traffic on the bus: set the NumLock LED. Harmless, no key reaches any app.
var ledState = false
func blinkNumLockLED() -> PokeResult {
    switch acquireKeyboard() {
    case .failure(.absent): return .absent
    case .failure(.denied(let r)): return .denied(r)
    case .failure(.failed(let s)): return .failed(s)
    case .success(let (dev, m)):
        defer { IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone)) }
        ledState.toggle()
        var report: [UInt8] = [ledState ? 0x01 : 0x00]  // bit0 = NumLock, no report ID
        let r = report.withUnsafeMutableBufferPointer { buf in
            IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0, buf.baseAddress!, buf.count)
        }
        return r == kIOReturnSuccess ? .ok("LED \(ledState ? "on" : "off")")
                                     : .failed("SetReport \(hex(Int(r)))")
    }
}

// MARK: - Key injection (fallback path)

func postKey(_ code: CGKeyCode) -> PokeResult {
    guard AXIsProcessTrusted() else { return .failed("not trusted for Accessibility, keystroke not sent") }
    let src = CGEventSource(stateID: .hidSystemState)
    guard let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true),
          let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false) else {
        return .failed("cannot build event")
    }
    down.flags = []
    up.flags = []
    down.post(tap: .cghidEventTap)
    usleep(20_000)
    up.post(tap: .cghidEventTap)
    return .ok("key \(code) sent")
}

// MARK: - Commands

func cmdDevices() -> Int32 {
    let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(m, nil)
    let openResult = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
    if openResult != kIOReturnSuccess { print("HID open: \(hex(Int(openResult))) (Input Monitoring not granted?)") }
    for d in devices(m) {
        let vid = intProp(d, kIOHIDVendorIDKey) ?? -1
        let pid = intProp(d, kIOHIDProductIDKey) ?? -1
        let name = strProp(d, kIOHIDProductKey) ?? "?"
        let transport = strProp(d, kIOHIDTransportKey) ?? "?"
        let mark = (vid == KB_VID && pid == KB_PID) ? " <== keyboard" : ""
        print("\(hex(vid))/\(hex(pid))  \(transport)  \(name)\(mark)")
    }
    IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
    return 0
}

func cmdStatus() -> Int32 {
    print("input monitoring : \(CGPreflightListenEventAccess())")
    print("accessibility    : \(AXIsProcessTrusted())")
    print("binary           : \(CommandLine.arguments[0])")
    switch acquireKeyboard() {
    case .success: print("keyboard         : present")
    case .failure(.absent): print("keyboard         : NOT PRESENT")
    case .failure(.denied(let r)): print("keyboard         : present but no access (\(hex(Int(r))))")
    case .failure(.failed(let s)): print("keyboard         : error \(s)")
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-fl", "keykeep poke"]
    try? p.run()
    p.waitUntilExit()
    return 0
}

func cmdPerms() -> Int32 {
    let pre = CGPreflightListenEventAccess()
    out("input monitoring before: \(pre)")
    if !pre {
        let ok = CGRequestListenEventAccess()
        out("CGRequestListenEventAccess -> \(ok)")
        out("if no dialog appeared: System Settings > Privacy & Security > Input Monitoring, add this binary, then restart the agent")
    }
    return 0
}

/// Ask for Input Monitoring the way a GUI app does, and stay alive while the dialog is up.
func cmdRequest(waitSeconds: Double) -> Int32 {
    if CGPreflightListenEventAccess() {
        out("input monitoring: already granted")
        return 0
    }
    #if canImport(AppKit)
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    NSApp.activate(ignoringOtherApps: true)
    #endif
    out("requesting Input Monitoring…")
    let ok = CGRequestListenEventAccess()
    out("CGRequestListenEventAccess -> \(ok)")
    let deadline = Date().addingTimeInterval(waitSeconds)
    while Date() < deadline {
        if CGPreflightListenEventAccess() {
            out("input monitoring: granted")
            return 0
        }
        Thread.sleep(forTimeInterval: 1)
    }
    out("still not granted after \(Int(waitSeconds))s — add the app manually in System Settings")
    return 1
}

func cmdWatch() -> Int32 {
    let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(m, nil)

    IOHIDManagerRegisterDeviceMatchingCallback(m, { _, _, _, dev in
        let vid = IOHIDDeviceGetProperty(dev, kIOHIDVendorIDKey as CFString) as? Int ?? -1
        let pid = IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int ?? -1
        guard vid == KB_VID && pid == KB_PID else { return }
        let name = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String ?? "?"
        out("ATTACH  \(hex(vid))/\(hex(pid)) \(name)")
    }, nil)

    IOHIDManagerRegisterDeviceRemovalCallback(m, { _, _, _, dev in
        let vid = IOHIDDeviceGetProperty(dev, kIOHIDVendorIDKey as CFString) as? Int ?? -1
        let pid = IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int ?? -1
        guard vid == KB_VID && pid == KB_PID else { return }
        out("DETACH  \(hex(vid))/\(hex(pid))")
    }, nil)

    IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    let r = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
    out("watching for keyboard drops (HID open: \(hex(Int(r)))) — Ctrl-C to stop")
    if r != kIOReturnSuccess {
        out("no Input Monitoring access: grant it to this binary, otherwise no events will be reported")
    }
    CFRunLoopRun()
    return 0
}

func cmdOnce() -> Int32 {
    for (name, res) in [("led", blinkNumLockLED()), ("key", postKey(71))] {
        switch res {
        case .ok(let s): out("\(name): \(s)")
        case .absent: out("\(name): keyboard not present")
        case .denied(let r): out("\(name): no Input Monitoring access (\(hex(Int(r))))")
        case .failed(let s): out("\(name): \(s)")
        }
    }
    return 0
}

func rotateLog(_ path: String) {
    let fm = FileManager.default
    guard let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int, size > 5_000_000 else { return }
    try? fm.removeItem(atPath: path + ".1")
    try? fm.moveItem(atPath: path, toPath: path + ".1")
}

func cmdPoke(args: [String]) -> Int32 {
    var interval = 5.0
    var keyCode: CGKeyCode? = nil
    var logPath: String? = nil
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--interval":
            i += 1
            if i < args.count, let v = Double(args[i]), v > 0.5 { interval = v }
        case "--key":
            i += 1
            if i < args.count, let v = UInt16(args[i]) { keyCode = CGKeyCode(v) }
        case "--led":
            keyCode = nil
        case "--log":
            i += 1
            if i < args.count, !args[i].isEmpty { logPath = args[i] }
        default:
            break
        }
        i += 1
    }
    if let lp = logPath { rotateLog(lp) }

    let mode = keyCode.map { "key \($0) injection (no USB traffic)" } ?? "LED report over USB"
    out("keykeep starting: every \(interval)s -> \(mode)")

    signal(SIGTERM) { _ in exit(0) }
    signal(SIGINT) { _ in exit(0) }

    var tick = 0
    var wasPresent = true
    var lastLine = ""
    var lastLoggedAt = Date.distantPast
    var deniedHinted = false

    while true {
        tick += 1
        let res = keyCode.map { postKey($0) } ?? blinkNumLockLED()

        var text: String
        var problem = false
        switch res {
        case .ok(let s):
            text = s
            if !wasPresent { out("keyboard back on the bus") ; wasPresent = true }
        case .absent:
            text = "keyboard not present"
            problem = true
            if wasPresent { out("keyboard DISAPPEARED from the bus") ; wasPresent = false }
        case .denied(let r):
            text = "no HID access (\(hex(Int(r))))"
            problem = true
            if !deniedHinted {
                deniedHinted = true
                out("hint: grant Input Monitoring to this binary (keykeep perms), then: launchctl kickstart -k gui/\(getuid())/ru.setere.keykeep")
            }
        case .failed(let s):
            text = s
            problem = true
        }

        let now = Date()
        let due = now.timeIntervalSince(lastLoggedAt) >= 60
        if problem || tick == 1 || (due && text != lastLine) {
            out("tick \(tick): \(text)")
            lastLine = text
            lastLoggedAt = now
        } else if due && !problem {
            out("tick \(tick): ok")
            lastLine = text
            lastLoggedAt = now
        }

        Thread.sleep(forTimeInterval: interval)
    }
}

func usage() {
    print("""
    keykeep <command>
      poke [--interval N] [--led | --key CODE] [--log PATH]   keep-alive loop (default: --led, 5s)
      once                                                    single poke, prints what happened
      watch                                                   log keyboard attach/detach events
      devices                                                 list HID devices
      status                                                  permissions, presence, running procs
      perms                                                   request Input Monitoring access
    """)
}

let argv = Array(CommandLine.arguments.dropFirst())
if argv.isEmpty {
    // launched from Keykeep.app: ask for Input Monitoring, hold the process while the dialog is up
    exit(cmdRequest(waitSeconds: 120))
}
guard let cmd = argv.first else { usage(); exit(2) }
switch cmd {
case "poke":    exit(cmdPoke(args: Array(argv.dropFirst())))
case "once":    exit(cmdOnce())
case "watch":   exit(cmdWatch())
case "devices": exit(cmdDevices())
case "status":  exit(cmdStatus())
case "perms":   exit(cmdPerms())
case "request": exit(cmdRequest(waitSeconds: 120))
default:        usage(); exit(2)
}
