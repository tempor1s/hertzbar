// HertzBar — a tiny menu bar app that injects a patched EDID into an external
// display on Apple Silicon, unlocking refresh rates macOS won't offer with the
// monitor's factory EDID.
//
// Build: ./build.sh     CLI: HertzBar.app/Contents/MacOS/HertzBar --status|--apply|--reset|--modes

import AppKit
import CoreGraphics
import IOKit
import IOKit.pwr_mgt
import ServiceManagement

// MARK: - Private IOKit (IOAVService) API

@_silgen_name("IOAVServiceCreateWithService")
private func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<CFTypeRef>?

@_silgen_name("IOAVServiceCopyEDID")
private func IOAVServiceCopyEDID(_ service: CFTypeRef, _ edid: UnsafeMutablePointer<Unmanaged<CFData>?>) -> IOReturn

// Undocumented: mode pointer = &1 with data applies a virtual EDID; (NULL, NULL) restores factory.
@_silgen_name("IOAVServiceSetVirtualEDIDMode")
private func IOAVServiceSetVirtualEDIDMode(_ service: CFTypeRef, _ mode: UnsafeMutablePointer<UInt32>?, _ edid: CFData?) -> IOReturn

// MARK: - EDID helpers

struct EDIDID: Equatable, CustomStringConvertible {
    let vendor: UInt16, product: UInt16
    init?(_ d: Data) {
        guard d.count >= 12, d.prefix(8) == Data([0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0]) else { return nil }
        let b = [UInt8](d)
        vendor = UInt16(b[8]) << 8 | UInt16(b[9])
        product = UInt16(b[10]) | UInt16(b[11]) << 8
    }
    var description: String { String(format: "vendor 0x%04X product 0x%04X", vendor, product) }
}

/// Copies the serial number (32-bit field + "serial string" descriptor) from the
/// display's live EDID into the override, so profiles can ship without anyone's
/// serial while macOS still recognizes the monitor as the same display (keeping
/// its saved resolution / arrangement).
func personalize(_ override: Data, with live: Data?) -> Data {
    guard let live, live.count >= 128, override.count >= 128,
          EDIDID(live) == EDIDID(override) else { return override }
    var o = [UInt8](override)
    let l = [UInt8](live)
    o[12..<16] = l[12..<16]
    for off in stride(from: 54, through: 108, by: 18)
    where o[off..<off + 4] == [0, 0, 0, 0xFF] && l[off..<off + 4] == [0, 0, 0, 0xFF] {
        o[off..<off + 18] = l[off..<off + 18]
    }
    o[127] = UInt8((256 - o[0..<127].reduce(0) { ($0 + Int($1)) & 0xFF }) & 0xFF)
    return Data(o)
}

func edidName(_ d: Data) -> String? {
    let b = [UInt8](d)
    for off in stride(from: 54, through: 108, by: 18) where b.count >= off + 18 {
        if b[off] == 0, b[off + 1] == 0, b[off + 3] == 0xFC {
            return String(bytes: b[(off + 5)..<(off + 18)], encoding: .ascii)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    return nil
}

// MARK: - Display service

struct AVDisplay {
    let service: CFTypeRef
    let location: String

    static func externals() -> [AVDisplay] {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &it) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(it) }
        var out: [AVDisplay] = []
        while case let s = IOIteratorNext(it), s != 0 {
            defer { IOObjectRelease(s) }
            let loc = IORegistryEntryCreateCFProperty(s, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String ?? "?"
            guard loc == "External", let av = IOAVServiceCreateWithService(kCFAllocatorDefault, s)?.takeRetainedValue() else { continue }
            out.append(AVDisplay(service: av, location: loc))
        }
        return out
    }

    var currentEDID: Data? {
        var ref: Unmanaged<CFData>?
        guard IOAVServiceCopyEDID(service, &ref) == kIOReturnSuccess, let d = ref?.takeRetainedValue() else { return nil }
        return d as Data
    }

    func apply(_ edid: Data) -> IOReturn {
        var mode: UInt32 = 1
        return IOAVServiceSetVirtualEDIDMode(service, &mode, edid as CFData)
    }

    func reset() -> IOReturn { IOAVServiceSetVirtualEDIDMode(service, nil, nil) }
}

// MARK: - Override store

enum Store {
    static let supportDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/HertzBar", isDirectory: true)
    static var userEDIDURL: URL { supportDir.appendingPathComponent("custom.edid") }

    /// Bundled example profiles (Resources/profiles/<id>.edid), for the Dell U4025QW.
    /// Each only applies to a monitor with the same vendor/product ID. "custom" = imported file.
    static let profiles: [(id: String, title: String)] = [
        ("100", "Dell U4025QW · 100 Hz"),
        ("110", "Dell U4025QW · 110 Hz (experimental)"),
        ("115", "Dell U4025QW · 115 Hz (experimental)"),
    ]

    static var profile: String {
        get { UserDefaults.standard.string(forKey: "profile") ?? "100" }
        set { UserDefaults.standard.set(newValue, forKey: "profile") }
    }

    static var overrideEDID: Data? {
        let id = profile
        if id == "custom" { return try? Data(contentsOf: userEDIDURL) }
        if let u = Bundle.main.url(forResource: id, withExtension: "edid", subdirectory: "profiles") {
            return try? Data(contentsOf: u)
        }
        return try? Data(contentsOf: URL(fileURLWithPath: "Resources/profiles/\(id).edid")) // CLI from repo root
    }

    static var autoApply: Bool {
        get { UserDefaults.standard.object(forKey: "autoApply") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoApply") }
    }
}

// MARK: - Core logic

enum Core {
    enum State { case noDisplay, noOverride, mismatch(EDIDID, EDIDID), applied, factory }

    /// Displays whose vendor/product matches the override EDID.
    static func targets() -> [AVDisplay] {
        guard let o = Store.overrideEDID, let oid = EDIDID(o) else { return [] }
        return AVDisplay.externals().filter { $0.currentEDID.flatMap(EDIDID.init) == oid }
    }

    static func state() -> State {
        guard let o = Store.overrideEDID, let oid = EDIDID(o) else { return .noOverride }
        let ext = AVDisplay.externals()
        guard let first = ext.first, let cur = first.currentEDID else { return .noDisplay }
        guard let d = ext.first(where: { $0.currentEDID.flatMap(EDIDID.init) == oid }), let e = d.currentEDID else {
            return .mismatch(EDIDID(cur) ?? oid, oid)
        }
        return e == personalize(o, with: e) ? .applied : .factory
    }

    @discardableResult
    static func apply(force: Bool = false, edid: Data? = nil) -> String {
        guard let o = edid ?? Store.overrideEDID else { return "No override EDID found" }
        let t = targets()
        if t.isEmpty { return "No matching external display connected" }
        var msgs: [String] = []
        for d in t {
            let live = d.currentEDID
            let edid = personalize(o, with: live)
            if !force, live == edid { msgs.append("already applied"); continue }
            let r = d.apply(edid)
            msgs.append(r == kIOReturnSuccess ? "applied" : String(format: "apply failed (0x%08X)", r))
        }
        if msgs.contains("applied") { nudgeDisplayPipeline() }
        return msgs.joined(separator: ", ")
    }

    /// The DCP only finishes re-probing the display with the new EDID once there's
    /// user activity (observed: it stalls on an idle Mac). Declaring activity, like
    /// `caffeinate -u`, kicks it along.
    static func nudgeDisplayPipeline() {
        for delay in [1.0, 4.0, 8.0] {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                var id: IOPMAssertionID = 0
                IOPMAssertionDeclareUserActivity("HertzBar EDID override" as CFString, kIOPMUserActiveLocal, &id)
                IOPMAssertionRelease(id)
            }
        }
    }

    @discardableResult
    static func reset() -> String {
        let t = targets()
        if t.isEmpty { return "No matching external display connected" }
        return t.map { d in
            let r = d.reset()
            return r == kIOReturnSuccess ? "restored factory EDID" : String(format: "reset failed (0x%08X)", r)
        }.joined(separator: ", ")
    }
}

// MARK: - Display modes (refresh rate switching via public CoreGraphics)

enum Modes {
    static func externalDisplayIDs() -> [CGDirectDisplayID] {
        var n: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &n)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
        CGGetOnlineDisplayList(n, &ids, &n)
        return ids.filter { CGDisplayIsBuiltin($0) == 0 }
    }

    static func all(_ id: CGDirectDisplayID) -> [CGDisplayMode] {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        return (CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode] ?? [])
    }

    /// Modes matching the current resolution (logical + pixel), one per refresh rate.
    static func refreshOptions(_ id: CGDirectDisplayID) -> [CGDisplayMode] {
        guard let cur = CGDisplayCopyDisplayMode(id) else { return [] }
        var seen = Set<Int>()
        return all(id)
            .filter { $0.width == cur.width && $0.height == cur.height && $0.pixelWidth == cur.pixelWidth && $0.pixelHeight == cur.pixelHeight }
            .sorted { $0.refreshRate > $1.refreshRate }
            .filter { seen.insert(Int(($0.refreshRate * 100).rounded())).inserted }
    }

    static func describe(_ m: CGDisplayMode) -> String {
        String(format: "%d×%d (%d×%d px) @ %.2f Hz", m.width, m.height, m.pixelWidth, m.pixelHeight, m.refreshRate)
    }
}

// MARK: - CLI

func runCLI(_ cmd: String) -> Never {
    switch cmd {
    case "--status":
        for d in AVDisplay.externals() {
            let e = d.currentEDID
            print("External AV service: \(e.flatMap(edidName) ?? "?") \(e.flatMap(EDIDID.init)?.description ?? "") \(e?.count ?? 0) bytes")
        }
        print("Override EDID: \(Store.overrideEDID.map { "\($0.count) bytes, \(EDIDID($0)?.description ?? "invalid")" } ?? "none")")
        print("State: \(Core.state())")
        for id in Modes.externalDisplayIDs() {
            if let m = CGDisplayCopyDisplayMode(id) { print("Display \(id) current: \(Modes.describe(m))") }
        }
    case "--apply":
        // Optional: --apply path/to/test.edid (one-off, doesn't change the saved override)
        let file = CommandLine.arguments.dropFirst(2).first { !$0.hasPrefix("--") }
        let data = file.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
        if file != nil && data == nil { print("Can't read \(file!)"); exit(1) }
        print(Core.apply(force: CommandLine.arguments.contains("--force"), edid: data))
        Thread.sleep(forTimeInterval: 9) // let the activity nudges fire before exiting
    case "--reset": print(Core.reset())
    case "--login-status":
        let s = SMAppService.mainApp.status
        print(s == .enabled ? "enabled" : s == .requiresApproval ? "requires approval (System Settings → General → Login Items)" : s == .notRegistered ? "not registered" : "not found")
    case "--dump":
        if let e = AVDisplay.externals().first?.currentEDID { FileHandle.standardOutput.write(e) }
    case "--modes":
        for id in Modes.externalDisplayIDs() {
            print("Display \(id):")
            for m in Modes.refreshOptions(id) { print("  " + Modes.describe(m)) }
        }
    default:
        print("usage: HertzBar [--status | --apply [file.edid] [--force] | --reset | --modes | --dump]")
    }
    exit(0)
}

// MARK: - Menu bar app

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private var pending: DispatchWorkItem?

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "HertzBar")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        // Re-apply when displays come back (reconnect, wake, KVM switch, etc.)
        CGDisplayRegisterReconfigurationCallback({ _, flags, ctx in
            guard flags.contains(.addFlag) || flags.contains(.enabledFlag), let ctx else { return }
            Unmanaged<AppDelegate>.fromOpaque(ctx).takeUnretainedValue().scheduleAutoApply()
        }, Unmanaged.passUnretained(self).toOpaque())
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.screensDidWakeNotification, object: nil)

        // First run: register as a login item so it's always there after boot.
        if !UserDefaults.standard.bool(forKey: "loginItemConfigured") {
            UserDefaults.standard.set(true, forKey: "loginItemConfigured")
            if SMAppService.mainApp.status != .enabled {
                do { try SMAppService.mainApp.register() } catch { NSLog("HertzBar login item: %@", "\(error)") }
            }
        }

        scheduleAutoApply(delay: 0.5)
    }

    @objc private func didWake() { scheduleAutoApply() }

    /// Debounced: the display pipeline fires several reconfig events in a row.
    func scheduleAutoApply(delay: TimeInterval = 2) {
        guard Store.autoApply else { return }
        pending?.cancel()
        let w = DispatchWorkItem { NSLog("HertzBar auto-apply: %@", Core.apply()) }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    // Rebuild the menu each time it opens so it always reflects live state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status: String
        switch Core.state() {
        case .applied: status = "✓ Override EDID active"
        case .factory: status = "Factory EDID (override not applied)"
        case .noDisplay: status = "No external display"
        case .noOverride: status = "No override EDID file"
        case let .mismatch(have, want): status = "Display doesn't match override (\(have) ≠ \(want))"
        }
        menu.addItem(disabled(status))

        for id in Modes.externalDisplayIDs() {
            if let m = CGDisplayCopyDisplayMode(id) { menu.addItem(disabled(Modes.describe(m))) }
        }

        menu.addItem(.separator())
        let psub = NSMenu()
        for (id, title) in Store.profiles + (FileManager.default.fileExists(atPath: Store.userEDIDURL.path) ? [("custom", "Custom (imported)")] : []) {
            let mi = action(title, #selector(pickProfile(_:)), "")
            mi.representedObject = id
            mi.state = Store.profile == id ? .on : .off
            psub.addItem(mi)
        }
        let pitem = NSMenuItem(title: "EDID Profile", action: nil, keyEquivalent: "")
        pitem.submenu = psub
        menu.addItem(pitem)
        menu.addItem(action("Apply Override EDID", #selector(applyNow), "a"))
        menu.addItem(action("Restore Factory EDID", #selector(resetNow), "r"))
        let auto = action("Auto-apply on Connect/Wake", #selector(toggleAuto), "")
        auto.state = Store.autoApply ? .on : .off
        menu.addItem(auto)
        let login = action("Launch at Login", #selector(toggleLogin), "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(action("Import Override EDID…", #selector(importEDID), ""))
        menu.addItem(.separator())
        menu.addItem(action("Quit HertzBar", #selector(quit), "q"))
    }

    private func disabled(_ t: String) -> NSMenuItem {
        let i = NSMenuItem(title: t, action: nil, keyEquivalent: ""); i.isEnabled = false; return i
    }

    private func action(_ t: String, _ s: Selector, _ k: String) -> NSMenuItem {
        let i = NSMenuItem(title: t, action: s, keyEquivalent: k); i.target = self; return i
    }

    @objc private func pickProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Store.profile = id
        notifyIfFailed(Core.apply(force: true))
    }

    @objc private func applyNow() { notifyIfFailed(Core.apply(force: true)) }
    @objc private func resetNow() { notifyIfFailed(Core.reset()) }
    @objc private func toggleAuto() { Store.autoApply.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { alert("Launch at Login failed: \(error.localizedDescription)") }
    }

    @objc private func importEDID() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = false
        p.message = "Choose a raw EDID binary (.bin / .edid)"
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK, let u = p.url, let d = try? Data(contentsOf: u) else { return }
        guard EDIDID(d) != nil, d.count % 128 == 0 else { return alert("That doesn't look like a raw EDID file.") }
        try? FileManager.default.createDirectory(at: Store.supportDir, withIntermediateDirectories: true)
        do { try d.write(to: Store.userEDIDURL); Store.profile = "custom"; notifyIfFailed(Core.apply(force: true)) }
        catch { alert(error.localizedDescription) }
    }

    private func notifyIfFailed(_ msg: String) {
        if msg.contains("fail") || msg.hasPrefix("No ") { alert(msg) }
    }

    private func alert(_ msg: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert(); a.messageText = "HertzBar"; a.informativeText = msg; a.runModal()
    }
}

// MARK: - Entry

if CommandLine.arguments.count > 1, CommandLine.arguments[1].hasPrefix("--") {
    runCLI(CommandLine.arguments[1])
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
