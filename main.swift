import SwiftUI
import AppKit
import CoreGraphics
import Carbon.HIToolbox
import ApplicationServices
import OSLog
import IOKit
import ServiceManagement

@main
struct FluorescentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene { Settings { EmptyView() } }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyTap: CFMachPort?
    private var mouseTap: CFMachPort?
    private var keySrc: CFRunLoopSource?
    private var mouseSrc: CFRunLoopSource?
    
    private var setupPollingTimer: Timer?

    private var commandDown = false
    private var switching = false

    private let mru = MRU()
    private let logger = Logger(subsystem: "org.kestell.fluorescent", category: "main")
    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? ProcessInfo.processInfo.processName
    }
    private var overlay: Overlay?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("Application starting up.")
        NSApp.setActivationPolicy(.accessory)

        // Register launch at login on first run
        registerLaunchAtLoginIfFirstRun()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.logger.debug("App activated: \(app.bundleIdentifier ?? "unknown")")
            self?.mru.push(app)
        }

        installStatusItem()
        seedMRUIfNeeded()
        
        setupPollingTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.checkPermissionsAndFinalizeSetup()
        }
    }

    private func registerLaunchAtLoginIfFirstRun() {
        guard #available(macOS 13.0, *) else { return }
        let defaults = UserDefaults.standard
        let key = "HasRegisteredLaunchAtLogin"
        if !defaults.bool(forKey: key) {
            do {
                try SMAppService.mainApp.register()
                defaults.set(true, forKey: key)
                logger.info("Registered app to launch at login (first run).")
            } catch {
                logger.error("Failed to register launch at login: \(String(describing: error))")
            }
        }
    }

    private func checkPermissionsAndFinalizeSetup() {
        logger.debug("Polling setup status...")

        if keyTap != nil {
            logger.debug("Setup is complete, polling is no longer necessary.")
            setupPollingTimer?.invalidate()
            setupPollingTimer = nil
            return
        }

        logger.debug("Checking Input Monitoring permission...")
        let imAccess = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        guard imAccess == kIOHIDAccessTypeGranted else {
            logger.debug("INPUT MONITORING NOT GRANTED (\(imAccess.rawValue))")
            if imAccess == kIOHIDAccessTypeUnknown {
                IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            }
            return
        }
        logger.debug("INPUT MONITORING GRANTED")

        logger.debug("Checking Accessibility permission...")
        guard isAccessibilityTrusted(prompt: false) else {
            logger.debug("ACCESSIBILITY NOT GRANTED")
            _ = isAccessibilityTrusted(prompt: true)
            return
        }
        logger.debug("ACCESSIBILITY GRANTED")

        logger.debug("Step 3: All permissions granted. Attempting to install key tap.")
        installKeyTap()
    }

    private func isAccessibilityTrusted(prompt: Bool) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }
    
    private func raiseAllWindows(of app: NSRunningApplication) {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
        guard err == .success, let windows = value as? [AXUIElement] else { return }
        for w in windows {
            var minimizedRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &minimizedRef) == .success {
                if let minimized = minimizedRef as? Bool, minimized { continue }
            }
            _ = AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let img = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: appName) {
                img.isTemplate = true
                button.image = img
            } else {
                let img = NSImage(size: NSSize(width: 18, height: 18))
                img.lockFocus()
                NSColor.labelColor.setStroke()
                let path = NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: 14, height: 14), xRadius: 3, yRadius: 3)
                path.lineWidth = 1.5
                path.stroke()
                img.unlockFocus()
                img.isTemplate = true
                button.image = img
            }
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "About \(appName)", action: #selector(showAbout(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit \(appName)", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.command]
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    @objc private func showAbout(_ sender: Any?) {
        var opts: [NSApplication.AboutPanelOptionKey: Any] = [:]
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String { opts[.version] = v }
        opts[.applicationName] = appName
        if let icon = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: nil) {
            opts[.applicationIcon] = icon
        }
        NSApp.orderFrontStandardAboutPanel(options: opts)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit(_ sender: Any?) { NSApp.terminate(nil) }

    private func seedMRUIfNeeded() {
        guard mru.isEmpty else { return }
        logger.info("MRU is empty, seeding...")
        if let ordered = zOrderedRegularApps(), !ordered.isEmpty {
            mru.seedInOrder(ordered); return
        }
        var apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        if let front = NSWorkspace.shared.frontmostApplication,
           let idx = apps.firstIndex(where: { $0.processIdentifier == front.processIdentifier }) {
            let f = apps.remove(at: idx); apps.insert(f, at: 0)
        }
        mru.seedInOrder(apps)
    }

    private func zOrderedRegularApps() -> [NSRunningApplication]? {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return nil }
        let byPID = Dictionary(uniqueKeysWithValues: NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) })
        var seen = Set<pid_t>(); var ordered: [NSRunningApplication] = []
        for w in info {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t else { continue }
            if seen.insert(pid).inserted, let app = byPID[pid], app.activationPolicy == .regular { ordered.append(app) }
        }
        return ordered
    }

    private func orderedAppsForOverlay() -> [NSRunningApplication] {
        let all = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        var seen = Set<String>(); var result: [NSRunningApplication] = []
        for id in mru.ids {
            if let app = all.first(where: { $0.bundleIdentifier == id }), seen.insert(id).inserted { result.append(app) }
        }
        for app in all {
            if let id = app.bundleIdentifier, seen.insert(id).inserted { result.append(app) }
        }
        return result
    }

    private func installKeyTap() {
        guard keyTap == nil else { return }
        logger.info("Attempting to install keyboard event tap.")
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        keyTap = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { (_: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? in
                let me = Unmanaged<AppDelegate>.fromOpaque(refcon!).takeUnretainedValue()
                return me.handleKeyEvent(type: type, event: event)
            },
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )
        guard let keyTap else {
            logger.error("Failed to create key tap. This may be a temporary timing issue.")
            return
        }
        keySrc = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, keyTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), keySrc, .commonModes)
        CGEvent.tapEnable(tap: keyTap, enable: true)
        logger.info("Successfully installed and enabled keyboard event tap.")
    }

    private func installMouseTap() {
        if mouseTap != nil { return }
        logger.info("Installing mouse event tap.")
        let types: [CGEventType] = [
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseUp, .rightMouseUp, .otherMouseUp,
            .scrollWheel, .mouseMoved,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged
        ]
        var mask: CGEventMask = 0; for t in types { mask |= 1 << t.rawValue }
        mouseTap = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { (_: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? in
                let me = Unmanaged<AppDelegate>.fromOpaque(refcon!).takeUnretainedValue()
                if me.switching {
                    let pt = event.location
                    if me.overlay?.hitTest(global: pt) == true {
                        return Unmanaged.passRetained(event)
                    } else {
                        return nil
                    }
                }
                return Unmanaged.passRetained(event)
            },
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )
        guard let mouseTap else {
            logger.error("Failed to create mouse tap.")
            return
        }
        mouseSrc = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, mouseTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), mouseSrc, .commonModes)
        CGEvent.tapEnable(tap: mouseTap, enable: true)
    }

    private func removeMouseTap() {
        logger.info("Removing mouse event tap.")
        if let s = mouseSrc { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), s, .commonModes) }
        if let t = mouseTap { CFMachPortInvalidate(t) }
        mouseSrc = nil; mouseTap = nil
    }

    private func handleKeyEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            logger.warning("Event tap was disabled, re-enabling.")
            if let keyTap { CGEvent.tapEnable(tap: keyTap, enable: true) }
            return Unmanaged.passRetained(event)
        }
        if type == .flagsChanged {
            let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
            let now = flags.contains(.command)
            if commandDown && !now && switching {
                logger.debug("Command key released, committing switch.")
                commit(); return nil
            }
            commandDown = now
            return switching ? nil : Unmanaged.passRetained(event)
        }

        guard type == .keyDown else { return Unmanaged.passRetained(event) }
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))

        if keyCode == Int(kVK_Tab) && flags.contains(.command) {
            if !switching {
                seedMRUIfNeeded()
                begin(reverse: flags.contains(.shift))
            } else {
                move(reverse: flags.contains(.shift))
            }
            return nil
        }

        if switching {
            logger.debug("Key press during switch: \(keyCode)")
            if keyCode == Int(kVK_Return) || keyCode == Int(kVK_ANSI_KeypadEnter) { commit(); return nil }
            if keyCode >= Int(kVK_ANSI_1) && keyCode <= Int(kVK_ANSI_9) { jump(keyCode - Int(kVK_ANSI_0)); return nil }
            if keyCode == Int(kVK_Escape) { cancel(); return nil }
            return nil
        }

        return Unmanaged.passRetained(event)
    }

    private func begin(reverse: Bool) {
        logger.info("Begin switching.")
        switching = true

        if overlay == nil {
            overlay = Overlay()
            overlay?.onActivate = { [weak self] app in
                guard let self else { return }
                self.logger.info("Click-activate \(app.bundleIdentifier ?? "none").")
                self.end()
                app.activate(options: [.activateIgnoringOtherApps])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self.raiseAllWindows(of: app)
                }
            }
        }

        overlay?.reload(orderedAppsForOverlay())
        overlay?.enableInteraction(true)
        overlay?.show()

        installMouseTap()

        if reverse { overlay?.moveBackward() } else { overlay?.moveForward() }
    }

    private func move(reverse: Bool) {
        logger.debug("Move selection \(reverse ? "backward" : "forward").")
        if reverse { overlay?.moveBackward() } else { overlay?.moveForward() }
    }

    private func jump(_ n: Int) {
        logger.debug("Jump to selection \(n).")
        overlay?.jump(to: n)
    }

    private func commit() {
        let app = overlay?.current
        logger.info("Committing switch to \((app?.bundleIdentifier ?? "none")).")
        end()
        app?.activate(options: [.activateIgnoringOtherApps])
        if let app {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.raiseAllWindows(of: app)
            }
        }
    }

    private func cancel() {
        logger.info("Cancelling switch.")
        end()
    }

    private func end() {
        switching = false
        overlay?.enableInteraction(false)
        overlay?.hide()
        removeMouseTap()
    }
}

final class MRU {
    private var list: [String] = []
    var isEmpty: Bool { list.isEmpty }
    var ids: [String] { list }

    func push(_ app: NSRunningApplication) {
        guard let id = app.bundleIdentifier else { return }
        list.removeAll { $0 == id }
        list.insert(id, at: 0)
    }

    func seedInOrder(_ apps: [NSRunningApplication]) {
        var seen = Set<String>(); list.removeAll(keepingCapacity: true)
        for a in apps {
            guard let id = a.bundleIdentifier, !seen.contains(id) else { continue }
            seen.insert(id); list.append(id)
        }
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           let idx = list.firstIndex(of: front) {
            list.remove(at: idx); list.insert(front, at: 0)
        }
    }
}
