// keykeep — keep a cheap USB keyboard alive, and report honestly what the device does.
//
//   keykeep poke [--interval 5] [--led | --key <code>] [--log PATH]   keep-alive loop
//   keykeep once                                                      single poke, prints what happened
//   keykeep probe                                                     open each interface, time it
//   keykeep watch                                                     log attach/detach events
//   keykeep devices                                                   list HID devices
//   keykeep status                                                    permissions, presence, interface
//   keykeep perms / request                                           Input Monitoring help
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

// Two interfaces belong to this keyboard: a keyboard one (usagePage 1 / usage 6)
// and a consumer-control one (usagePage 12 / usage 1). The LED report only makes
// sense on the keyboard interface, so it is picked explicitly, never by Set order.
let USAGE_PAGE_LED = 0x08
let USAGE_PAGE_GENERIC_DESKTOP = 0x01
let USAGE_KEYBOARD = 0x06

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

/// Human name for the codes this device actually returns.
func iorName(_ r: IOReturn) -> String {
    switch UInt32(bitPattern: r) {
    case 0x00000000: return "kIOReturnSuccess"
    case 0xe00002c0: return "kIOReturnNoDevice"
    case 0xe00002c5: return "kIOReturnExclusiveAccess"
    case 0xe00002c7: return "kIOReturnUnsupported"
    case 0xe00002cd: return "kIOReturnNotOpen"
    case 0xe00002d6: return "kIOReturnTimeout"
    case 0xe00002d9: return "kIOReturnNotAttached"
    case 0xe00002e2: return "kIOReturnNotPermitted"
    case 0xe00002eb: return "kIOReturnAborted"
    case 0xe00002f0: return "kIOReturnNotFound"
    default:         return "IOReturn"
    }
}

// MARK: - HID access

func newManager(vid: Int, pid: Int) -> IOHIDManager {
    let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    let match: [String: Any] = [kIOHIDVendorIDKey: vid, kIOHIDProductIDKey: pid]
    IOHIDManagerSetDeviceMatching(m, match as CFDictionary)
    return m
}

/// Manager matching every HID device — used when the keyboard's identities must be inspected.
func newUnfilteredManager() -> IOHIDManager {
    let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(m, nil)
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

func usagePage(_ d: IOHIDDevice) -> Int { intProp(d, kIOHIDPrimaryUsagePageKey) ?? -1 }
func usage(_ d: IOHIDDevice) -> Int { intProp(d, kIOHIDPrimaryUsageKey) ?? -1 }

/// Number of LED output elements (NumLock / CapsLock / ScrollLock) on this interface.
func ledOutputs(_ d: IOHIDDevice) -> Int {
    let match: [String: Any] = [kIOHIDElementUsagePageKey: USAGE_PAGE_LED]
    guard let cf = IOHIDDeviceCopyMatchingElements(d, match as CFDictionary, 0) else { return 0 }
    let items = cf as! [Any]
    let outputType = kIOHIDElementTypeOutput.rawValue
    var n = 0
    for item in items {
        let e = item as! IOHIDElement
        if IOHIDElementGetType(e).rawValue == outputType { n += 1 }
    }
    return n
}

func describe(_ d: IOHIDDevice) -> String {
    let name = strProp(d, kIOHIDProductKey) ?? "?"
    return "\(name) usagePage \(usagePage(d))/usage \(usage(d)), LED elements \(ledOutputs(d))"
}

/// The keyboard interface wins; failing that, whatever has LED elements; failing that, anything.
func pickInterface(_ devs: [IOHIDDevice]) -> IOHIDDevice? {
    func score(_ d: IOHIDDevice) -> Int {
        var s = 0
        if usagePage(d) == USAGE_PAGE_GENERIC_DESKTOP && usage(d) == USAGE_KEYBOARD { s += 20 }
        if usagePage(d) == USAGE_PAGE_LED { s += 15 }
        if ledOutputs(d) > 0 { s += 10 }
        return s
    }
    return devs.max { score($0) < score($1) }
}

enum Cancel: Error {
    case absent
    case denied(IOReturn)
    case openFailed(IOReturn)
}

/// Open the keyboard. Returns the chosen interface plus the millisecond cost of the open.
func openKeyboard() -> Result<(dev: IOHIDDevice, manager: IOHIDManager, ms: Int), Cancel> {
    let t0 = Date()
    let m = newManager(vid: KB_VID, pid: KB_PID)
    let r = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
    let ms = Int(Date().timeIntervalSince(t0) * 1000)
    if r != kIOReturnSuccess {
        IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
        return .failure(r == kIOReturnNotPermitted ? .denied(r) : .openFailed(r))
    }
    let devs = devices(m)
    guard let dev = pickInterface(devs) else {
        IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
        return .failure(.absent)
    }
    return .success((dev, m, ms))
}

// MARK: - One attempt

enum Outcome {
    case ok          // отчёт ушёл
    case absent      // устройства нет на шине
    case noAccess    // нет разрешения Input Monitoring
    case openFailed  // устройство есть, open не удался (в т.ч. после долгого стойла)
    case rejected    // открылось, но отчёт не принят
}

struct Attempt {
    let outcome: Outcome
    let detail: String
    let ms: Int
    /// true, если операция висела заметное время — верный признак заклинившего устройства
    var stalled: Bool { ms > 2000 }
}

var ledState = false

func ledAttempt() -> Attempt {
    switch openKeyboard() {
    case .failure(.absent):
        return Attempt(outcome: .absent, detail: "keyboard not present on the bus", ms: 0)
    case .failure(.denied(let r)):
        return Attempt(outcome: .noAccess,
                       detail: "open denied \(hex(Int(r))) \(iorName(r))", ms: 0)
    case .failure(.openFailed(let r)):
        return Attempt(outcome: .openFailed,
                       detail: "open failed \(hex(Int(r))) \(iorName(r))", ms: 0)
    case .success(let (dev, m, openMs)):
        defer { IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone)) }
        ledState.toggle()
        var report: [UInt8] = [ledState ? 0x01 : 0x00]   // bit0 = NumLock, no report ID
        let t0 = Date()
        let r = report.withUnsafeMutableBufferPointer { buf in
            IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0, buf.baseAddress!, buf.count)
        }
        let ms = openMs + Int(Date().timeIntervalSince(t0) * 1000)
        let where_ = "usagePage \(usagePage(dev))/usage \(usage(dev))"
        if r == kIOReturnSuccess {
            return Attempt(outcome: .ok, detail: "LED \(ledState ? "on" : "off") via \(where_)", ms: ms)
        }
        if r == kIOReturnNotPermitted {
            return Attempt(outcome: .noAccess,
                           detail: "SetReport denied \(hex(Int(r))) \(iorName(r))", ms: ms)
        }
        return Attempt(outcome: .rejected,
                       detail: "SetReport \(hex(Int(r))) \(iorName(r)) via \(where_)", ms: ms)
    }
}

// MARK: - Key injection (fallback path)

func postKey(_ code: CGKeyCode) -> Attempt {
    guard AXIsProcessTrusted() else {
        return Attempt(outcome: .noAccess, detail: "not trusted for Accessibility, keystroke not sent", ms: 0)
    }
    let t0 = Date()
    let src = CGEventSource(stateID: .hidSystemState)
    guard let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true),
          let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false) else {
        return Attempt(outcome: .rejected, detail: "cannot build event", ms: 0)
    }
    down.flags = []
    up.flags = []
    down.post(tap: .cghidEventTap)
    usleep(20_000)
    up.post(tap: .cghidEventTap)
    return Attempt(outcome: .ok, detail: "key \(code) sent",
                   ms: Int(Date().timeIntervalSince(t0) * 1000))
}

// MARK: - Commands

func cmdDevices() -> Int32 {
    let m = newUnfilteredManager()
    let r = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
    if r != kIOReturnSuccess {
        print("HID open: \(hex(Int(r))) \(iorName(r)) — Input Monitoring not granted?")
    }
    for d in devices(m) {
        let vid = intProp(d, kIOHIDVendorIDKey) ?? -1
        let pid = intProp(d, kIOHIDProductIDKey) ?? -1
        let transport = strProp(d, kIOHIDTransportKey) ?? "?"
        let mark = (vid == KB_VID && pid == KB_PID) ? " <== keyboard" : ""
        print("\(hex(vid))/\(hex(pid))  \(transport)  usagePage \(usagePage(d))/usage \(usage(d))  LEDs \(ledOutputs(d))  \(strProp(d, kIOHIDProductKey) ?? "?")\(mark)")
    }
    IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
    return 0
}

/// Time each interface open separately: a multi-second open is the device stalling, not a permission problem.
func cmdProbe() -> Int32 {
    let t0 = Date()
    let m = newManager(vid: KB_VID, pid: KB_PID)
    let r = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
    print("manager open       : \(hex(Int(r))) \(iorName(r)) after \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
    guard r == kIOReturnSuccess else { return 1 }
    let devs = devices(m)
    print("interfaces found   : \(devs.count)")
    for d in devs {
        let t = Date()
        let o = IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone))
        let dt = Date().timeIntervalSince(t)
        print("  \(describe(d))")
        print("    open \(hex(Int(o))) \(iorName(o)) after \(String(format: "%.2f", dt))s")
        if o == kIOReturnSuccess {
            var report: [UInt8] = [0x01]
            let s = report.withUnsafeMutableBufferPointer { buf in
                IOHIDDeviceSetReport(d, kIOHIDReportTypeOutput, 0, buf.baseAddress!, buf.count)
            }
            print("    SetReport \(hex(Int(s))) \(iorName(s))")
            IOHIDDeviceClose(d, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }
    if let best = pickInterface(devs) { print("picked interface   : \(describe(best))") }
    IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
    return 0
}

// MARK: - Recovery (safe path only: IOServiceRequestProbe)

func services(_ className: String, vidKey: String, pidKey: String) -> [io_service_t] {
    var iter: io_iterator_t = 0
    guard let match = IOServiceMatching(className) else { return [] }
    guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(iter) }
    var found: [io_service_t] = []
    var svc = IOIteratorNext(iter)
    while svc != 0 {
        let v = (IORegistryEntryCreateCFProperty(svc, vidKey as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? NSNumber)?.intValue ?? -1
        let p = (IORegistryEntryCreateCFProperty(svc, pidKey as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? NSNumber)?.intValue ?? -1
        if v == KB_VID && p == KB_PID { found.append(svc) } else { IOObjectRelease(svc) }
        svc = IOIteratorNext(iter)
    }
    return found
}

/// Ask the kernel to re-probe the keyboard's nodes. Safe: no driver reload, no port power cycling,
/// no seize — if the driver has nothing to re-probe this is a no-op with a return code.
func requestProbe() -> (usb: Int, hid: Int, codes: [String]) {
    var codes: [String] = []
    var usbCount = 0, hidCount = 0
    for s in services("IOUSBHostDevice", vidKey: "idVendor", pidKey: "idProduct") {
        let r = IOServiceRequestProbe(s, 0)
        codes.append("IOUSBHostDevice: \(hex(Int(r))) \(iorName(r))")
        usbCount += 1
        IOObjectRelease(s)
    }
    for s in services("IOHIDDevice", vidKey: kIOHIDVendorIDKey, pidKey: kIOHIDProductIDKey) {
        let r = IOServiceRequestProbe(s, 0)
        codes.append("IOHIDDevice: \(hex(Int(r))) \(iorName(r))")
        hidCount += 1
        IOObjectRelease(s)
    }
    return (usbCount, hidCount, codes)
}

func describeOpen(_ r: Result<(dev: IOHIDDevice, manager: IOHIDManager, ms: Int), Cancel>) -> String {
    switch r {
    case .success(let (dev, m, ms)):
        let s = "opens in \(ms) ms (\(describe(dev)))"
        IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
        return s
    case .failure(.absent):           return "not present on the bus"
    case .failure(.denied(let e)):    return "no access \(hex(Int(e))) \(iorName(e))"
    case .failure(.openFailed(let e)): return "open failed \(hex(Int(e))) \(iorName(e))"
    }
}

func cmdRecover() -> Int32 {
    out("recover: before — \(describeOpen(openKeyboard()))")
    let p = requestProbe()
    if p.usb + p.hid == 0 {
        out("recover: no kernel nodes for this keyboard — nothing to re-probe")
        return 1
    }
    out("recover: re-probe requested for \(p.usb) USB and \(p.hid) HID node(s)")
    for c in p.codes { out("  \(c)") }
    Thread.sleep(forTimeInterval: 0.5)
    out("recover: after — \(describeOpen(openKeyboard()))")
    return 0
}

func cmdStatus() -> Int32 {
    print("input monitoring : \(CGPreflightListenEventAccess())")
    print("accessibility    : \(AXIsProcessTrusted())")
    print("binary           : \(CommandLine.arguments[0])")
    fflush(stdout)
    switch openKeyboard() {
    case .success(let (dev, m, ms)):
        print("keyboard         : open in \(ms) ms — \(describe(dev))")
        IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
    case .failure(.absent):
        print("keyboard         : NOT PRESENT on the bus")
    case .failure(.denied(let r)):
        print("keyboard         : no Input Monitoring access (\(hex(Int(r))) \(iorName(r)))")
    case .failure(.openFailed(let r)):
        print("keyboard         : open failed (\(hex(Int(r))) \(iorName(r)))")
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
    let m = newUnfilteredManager()

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
    out("watching for keyboard drops (HID open: \(hex(Int(r))) \(iorName(r))) — Ctrl-C to stop")
    if r != kIOReturnSuccess {
        out("open failed: without Input Monitoring nothing will be reported")
    }
    CFRunLoopRun()
    return 0
}

func cmdOnce() -> Int32 {
    let a = ledAttempt()
    out("led: \(a.detail) (\(a.ms) ms)")
    let k = postKey(71)
    out("key: \(k.detail) (\(k.ms) ms)")
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
    var backoff = 60.0
    var recoverEvery = 300.0
    var keyCode: CGKeyCode? = nil
    var logPath: String? = nil
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--interval":
            i += 1
            if i < args.count, let v = Double(args[i]), v > 0.5 { interval = v }
        case "--backoff":
            i += 1
            if i < args.count, let v = Double(args[i]), v >= 1 { backoff = v }
        case "--recover-every":
            i += 1
            if i < args.count, let v = Double(args[i]), v >= 0 { recoverEvery = v }
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
    out("keykeep starting: every \(interval)s (backoff \(backoff)s, re-probe every \(Int(recoverEvery))s) -> \(mode)")

    signal(SIGTERM) { _ in exit(0) }
    signal(SIGINT) { _ in exit(0) }

    var tick = 0
    var previous: Outcome? = nil
    var inBackoff = false
    var lastLoggedAt = Date.distantPast
    var lastDetail = ""
    var lastRecoverAt = Date.distantPast

    while true {
        tick += 1
        let a = keyCode.map { postKey($0) } ?? ledAttempt()

        // переходы состояний — самое важное в логе
        if a.outcome != previous {
            switch a.outcome {
            case .ok:         out("state: OK — \(a.detail) (\(a.ms) ms)")
            case .absent:     out("state: keyboard DISAPPEARED from the bus")
            case .noAccess:   out("state: NO ACCESS — \(a.detail)")
                                  out("hint: System Settings > Privacy & Security > Input Monitoring > enable Keykeep, then: launchctl kickstart -k gui/\(getuid())/ru.setere.keykeep")
            case .openFailed: out("state: OPEN FAILED — \(a.detail) (\(a.ms) ms)")
            case .rejected:   out("state: REPORT REJECTED — \(a.detail)")
            }
            previous = a.outcome
            lastLoggedAt = Date()
            lastDetail = a.detail
        }

        // стойло на open — устройство заклинило; долбиться каждые 5 с бессмысленно
        let shouldBackOff = (a.outcome == .openFailed || a.outcome == .rejected) && a.stalled
        if shouldBackOff && !inBackoff {
            inBackoff = true
            out("open stalled \(a.ms) ms — backing off to \(Int(backoff))s until the device answers again")
        }
        if a.outcome == .ok && inBackoff {
            inBackoff = false
            out("recovered — back to \(Int(interval))s")
        }

        // устройство заклинило или пропало: вежливо просим ядро переопросить его узлы.
        // Это безопасный вызов — перезагрузки драйвера и питания порта здесь нет.
        if (a.outcome == .openFailed || a.outcome == .absent) && recoverEvery > 0,
           Date().timeIntervalSince(lastRecoverAt) >= recoverEvery {
            lastRecoverAt = Date()
            let p = requestProbe()
            if p.usb + p.hid == 0 {
                out("re-probe: no kernel nodes for the keyboard")
            } else {
                out("re-probe: asked \(p.usb) USB and \(p.hid) HID node(s) to re-probe")
                for c in p.codes { out("  \(c)") }
            }
        }

        // периодическая отметка, чтобы в логе была видна жизнь
        let due = Date().timeIntervalSince(lastLoggedAt) >= 60
        if due && a.outcome != .ok {
            out("tick \(tick): \(a.detail) (\(a.ms) ms)")
            lastLoggedAt = Date()
            lastDetail = a.detail
        } else if due && a.outcome == .ok {
            out("tick \(tick): ok, \(a.detail) (\(a.ms) ms)")
            lastLoggedAt = Date()
            lastDetail = a.detail
        }
        _ = lastDetail

        Thread.sleep(forTimeInterval: inBackoff ? backoff : interval)
    }
}

func usage() {
    print("""
    keykeep <command>
      poke [--interval N] [--backoff N] [--recover-every N] [--led | --key CODE] [--log PATH]
                                            keep-alive loop (default: --led, 5s, backoff 60s, re-probe 300s)
      once                                  single poke, prints what happened and how long it took
      probe                                 open every interface separately, with timings
      recover                               ask the kernel to re-probe the keyboard, before/after
      watch                                 log keyboard attach/detach events
      devices                               list HID devices with usage page and LED elements
      status                                permissions, presence, chosen interface
      perms | request                        Input Monitoring help
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
case "probe":   exit(cmdProbe())
case "recover": exit(cmdRecover())
case "watch":   exit(cmdWatch())
case "devices": exit(cmdDevices())
case "status":  exit(cmdStatus())
case "perms":   exit(cmdPerms())
case "request": exit(cmdRequest(waitSeconds: 120))
default:        usage(); exit(2)
}
