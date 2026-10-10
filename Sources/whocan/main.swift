// whocan — one screen for every macOS privacy permission your terminal has.
//
// macOS attributes TCC permissions to the "responsible process", so when this
// binary is launched from a terminal, every check below reports the terminal
// app's grants. Only public, non-prompting preflight APIs are used: nothing
// here asks for a permission or reads the TCC database.
//
// Usage:  whocan              show the table
//         whocan --json       machine-readable output
//         whocan open <key>   jump to that pane in System Settings (e.g. `open camera`)

import AVFoundation
import AppKit
import ApplicationServices
import Contacts
import CoreBluetooth
import CoreLocation
import EventKit
import Foundation
import Photos
import Speech

// Color only when writing to a terminal and NO_COLOR (https://no-color.org) is unset.
let useColor = isatty(STDOUT_FILENO) != 0 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil

func paint(_ code: String, _ text: String) -> String {
    useColor ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
}

enum Status: String {
    case granted = "granted"
    case denied = "denied"
    case notAsked = "not asked"
    case restricted = "restricted"
    case off = "off"
    case unknown = "unknown"

    var symbol: String {
        switch self {
        case .granted: return paint("32", "●")
        case .denied: return paint("31", "●")
        case .restricted: return paint("33", "●")
        case .notAsked, .off, .unknown: return paint("90", "○")
        }
    }
}

struct Check {
    let key: String
    let name: String
    let pane: String  // anchor for x-apple.systempreferences:com.apple.preference.security?<pane>
    let probe: () -> (Status, String?)
}

// MARK: - Probes

func av(_ type: AVMediaType) -> (Status, String?) {
    switch AVCaptureDevice.authorizationStatus(for: type) {
    case .authorized: return (.granted, nil)
    case .denied: return (.denied, nil)
    case .restricted: return (.restricted, nil)
    case .notDetermined: return (.notAsked, nil)
    @unknown default: return (.unknown, nil)
    }
}

func eventKit(_ type: EKEntityType) -> (Status, String?) {
    let s = EKEventStore.authorizationStatus(for: type)
    switch s {
    case .denied: return (.denied, nil)
    case .restricted: return (.restricted, nil)
    case .notDetermined: return (.notAsked, nil)
    default:
        if #available(macOS 14.0, *) {
            if s == .fullAccess { return (.granted, nil) }
            if s == .writeOnly { return (.granted, "write only") }
        }
        return s.rawValue == 3 ? (.granted, nil) : (.unknown, nil)  // 3 == legacy .authorized
    }
}

func bool(_ b: Bool) -> (Status, String?) { b ? (.granted, nil) : (.off, "denied or never asked") }

let checks: [Check] = [
    Check(key: "accessibility", name: "Accessibility", pane: "Privacy_Accessibility") {
        bool(AXIsProcessTrusted())
    },
    Check(key: "screen", name: "Screen & System Audio Recording", pane: "Privacy_ScreenCapture") {
        bool(CGPreflightScreenCaptureAccess())
    },
    Check(key: "input", name: "Input Monitoring", pane: "Privacy_ListenEvent") {
        bool(CGPreflightListenEventAccess())
    },
    Check(key: "camera", name: "Camera", pane: "Privacy_Camera") { av(.video) },
    Check(key: "microphone", name: "Microphone", pane: "Privacy_Microphone") { av(.audio) },
    Check(key: "contacts", name: "Contacts", pane: "Privacy_Contacts") {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: return (.granted, nil)
        case .denied: return (.denied, nil)
        case .restricted: return (.restricted, nil)
        case .notDetermined: return (.notAsked, nil)
        default: return (.granted, "limited")
        }
    },
    Check(key: "calendars", name: "Calendars", pane: "Privacy_Calendars") { eventKit(.event) },
    Check(key: "reminders", name: "Reminders", pane: "Privacy_Reminders") { eventKit(.reminder) },
    Check(key: "photos", name: "Photos", pane: "Privacy_Photos") {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized: return (.granted, nil)
        case .limited: return (.granted, "limited")
        case .denied: return (.denied, nil)
        case .restricted: return (.restricted, nil)
        case .notDetermined: return (.notAsked, nil)
        @unknown default: return (.unknown, nil)
        }
    },
    Check(key: "location", name: "Location Services", pane: "Privacy_LocationServices") {
        guard CLLocationManager.locationServicesEnabled() else { return (.denied, "disabled system-wide") }
        switch CLLocationManager().authorizationStatus {
        case .authorizedAlways: return (.granted, nil)
        case .denied: return (.denied, nil)
        case .restricted: return (.restricted, nil)
        case .notDetermined: return (.notAsked, nil)
        default: return (.granted, nil)
        }
    },
    Check(key: "bluetooth", name: "Bluetooth", pane: "Privacy_Bluetooth") {
        switch CBManager.authorization {
        case .allowedAlways: return (.granted, nil)
        case .denied: return (.denied, nil)
        case .restricted: return (.restricted, nil)
        case .notDetermined: return (.notAsked, nil)
        @unknown default: return (.unknown, nil)
        }
    },
    Check(key: "speech", name: "Speech Recognition", pane: "Privacy_SpeechRecognition") {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return (.granted, nil)
        case .denied: return (.denied, nil)
        case .restricted: return (.restricted, nil)
        case .notDetermined: return (.notAsked, nil)
        @unknown default: return (.unknown, nil)
        }
    },
    Check(key: "automation", name: "Automation", pane: "Privacy_Automation") {
        // Non-prompting check against a few common Apple Event targets. macOS can only
        // answer for targets that are running; others return procNotFound.
        let targets = ["com.apple.systemevents", "com.apple.finder", "com.apple.Terminal", "com.apple.Safari"]
        var allowed: [String] = [], denied: [String] = [], notRunning: [String] = []
        for id in targets {
            var desc = AEAddressDesc()
            guard AECreateDesc(typeApplicationBundleID, id, id.utf8.count, &desc) == noErr else { continue }
            defer { AEDisposeDesc(&desc) }
            let err = AEDeterminePermissionToAutomateTarget(&desc, typeWildCard, typeWildCard, false)
            let short = id.split(separator: ".").last.map(String.init) ?? id
            if err == noErr { allowed.append(short) }
            else if err == OSStatus(errAEEventNotPermitted) { denied.append(short) }
            else if err == OSStatus(procNotFound) { notRunning.append(short) }
        }
        var parts: [String] = []
        if !allowed.isEmpty { parts.append(allowed.joined(separator: ", ")) }
        if !denied.isEmpty { parts.append("denied: " + denied.joined(separator: ", ")) }
        if !notRunning.isEmpty { parts.append("not running, unchecked: " + notRunning.joined(separator: ", ")) }
        let note = parts.isEmpty ? nil : parts.joined(separator: " · ")
        if !allowed.isEmpty { return (.granted, note) }
        if !denied.isEmpty { return (.denied, note) }
        if notRunning.count == targets.count { return (.unknown, note) }
        return (.notAsked, note)
    },
    // No public, non-intrusive API exists for these; link to the pane instead.
    Check(key: "fda", name: "Full Disk Access", pane: "Privacy_AllFiles") { (.unknown, "check in Settings") },
    Check(key: "files", name: "Files & Folders", pane: "Privacy_FilesAndFolders") { (.unknown, "check in Settings") },
    Check(key: "devtools", name: "Developer Tools", pane: "Privacy_DevTools") { (.unknown, "check in Settings") },
    Check(key: "network", name: "Local Network", pane: "Privacy_LocalNetwork") { (.unknown, "check in Settings") },
]

// MARK: - Terminal identity

func terminalName() -> String {
    let env = ProcessInfo.processInfo.environment
    if let id = env["__CFBundleIdentifier"],
       let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
        return "\(FileManager.default.displayName(atPath: url.path)) (\(id))"
    }
    return env["TERM_PROGRAM"] ?? "this terminal"
}

func settingsURL(_ pane: String) -> URL {
    URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
}

// MARK: - Main

let version = "0.1.1"
let args = Array(CommandLine.arguments.dropFirst())

if args.contains("--version") || args.contains("-v") {
    print("whocan \(version)")
    exit(0)
}

if args.contains("--help") || args.contains("-h") {
    print("""
    whocan \(version) — every macOS privacy permission your terminal has, on one screen

    usage: whocan              show the table
           whocan --json       machine-readable output
           whocan open <key>   open that pane in System Settings

    keys: \(checks.map(\.key).joined(separator: " "))
    """)
    exit(0)
}

if args.first == "open" {
    guard args.count > 1, let c = checks.first(where: { $0.key == args[1] }) else {
        print("usage: whocan open <\(checks.map(\.key).joined(separator: "|"))>")
        exit(1)
    }
    NSWorkspace.shared.open(settingsURL(c.pane))
    exit(0)
}

let results = checks.map { c -> (Check, Status, String?) in
    let (s, note) = c.probe()
    return (c, s, note)
}

if args.contains("--json") {
    let rows = results.map { c, s, note -> [String: String] in
        var r = ["key": c.key, "name": c.name, "status": s.rawValue, "settings": settingsURL(c.pane).absoluteString]
        if let note { r["note"] = note }
        return r
    }
    let out: [String: Any] = ["terminal": terminalName(), "permissions": rows]
    let data = try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8)!)
    exit(0)
}

let width = checks.map(\.name.count).max()!
print("\n  Privacy permissions for \(paint("1", terminalName()))\n")
for (c, s, note) in results {
    let name = c.name.padding(toLength: width, withPad: " ", startingAt: 0)
    let status = s.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)
    let extra = note.map { paint("90", $0) } ?? ""
    print("  \(s.symbol) \(name)  \(status) \(extra)")
}
print("\n  " + paint("90", "whocan open <key> to jump to a pane · keys: \(checks.map(\.key).joined(separator: " "))") + "\n")
