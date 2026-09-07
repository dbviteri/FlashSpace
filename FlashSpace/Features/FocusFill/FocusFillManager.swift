//
//  FocusFillManager.swift
//
//  Minimal replacement for FlashSpace:
//  On app focus -> fill the focused window (native Fn-Ctrl-F behavior)
//  and hide all other regular apps.
//

import AppKit
import Combine

final class FocusFillManager {
    static let shared = FocusFillManager()

    /// Margin left around the filled window, mimicking native Fill
    /// which leaves a small border instead of covering the full visibleFrame.
    private let fillMargin: CGFloat = 8

    /// Bundle IDs of apps whose windows refused a fill. They go straight
    /// to centre on focus, with no fill attempt (and no flicker).
    /// Pre-seeded with System Settings, the app that motivated this.
    private let fixedSizeDefaultsKey = "fixedSizeBundleIDs"
    private lazy var fixedSizeApps: Set<String> = {
        var cached = Set(UserDefaults.standard.stringArray(forKey: fixedSizeDefaultsKey) ?? [])
        cached.insert("com.apple.systempreferences")
        return cached
    }()

    private var cancellables = Set<AnyCancellable>()
    private var isHandling = false

    /// AX observer for window open/close/focus events in the frontmost app.
    /// App activation alone misses intra-app changes, e.g. closing the last
    /// window leaves Finder on a bare (but still dimmed) desktop.
    private var windowObserver: AXObserver?
    private var observedPID: pid_t = -1
    private var windowEventGen = 0

    /// Show Desktop / Mission Control watchdog. The trackpad spread gesture
    /// posts no observable notification, so while the dim is up we poll
    /// whether the filled window is still on screen and hide/re-show the
    /// dim accordingly. Runs only while the dim is shown.
    private var watchdogTimer: Timer?
    private var lastFilledFrame: CGRect?
    private var lastFilledPID: pid_t?
    private var watchdogConcealed = false

    private init() {}

    func start() {
        PermissionsManager.shared.askForAccessibilityPermissions()

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .filter { $0.activationPolicy == .regular }
            .removeDuplicates()
            .sink { [weak self] app in self?.handleFocus(app) }
            .store(in: &cancellables)

        // Apply to the already-focused app on launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, let frontmost = NSWorkspace.shared.frontmostApplication else { return }
            guard frontmost.activationPolicy == .regular else { return }
            self.handleFocus(frontmost)
        }
    }

    private func handleFocus(_ app: NSRunningApplication) {
        guard !isHandling else { return }
        guard PermissionsManager.shared.checkForAccessibilityPermissions() else {
            Logger.log("Missing accessibility permissions - skipping fill+hide")
            return
        }

        isHandling = true
        defer { isHandling = false }

        observeWindows(of: app)

        // Bare-desktop Finder focus isolates nothing: hiding the other apps
        // here would strand spread-away windows - Show Desktop could no
        // longer restore them on desktop click. (Native macOS also hides
        // nothing when the desktop takes focus.)
        if !isBareFinderDesktop(app) {
            hideOtherApps(except: app)
        }

        // Small delay: the newly activated window may not be ready via AX yet.
        // Guarded: if focus already moved on, this run is stale - abort it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard self?.isStillFrontmost(app) == true else { return }
            self?.fillFocusedWindow(of: app, attempt: 1)
        }

        // Delayed sweep: catch apps that reappeared or were missed
        // (e.g. slow-activating apps like Chrome unhiding late).
        // Same staleness guard: never hide on behalf of an app that
        // is no longer focused, or we'd hide the newly focused app.
        // Skipped for bare-desktop Finder (see above).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard self?.isStillFrontmost(app) == true else { return }
            guard self?.isBareFinderDesktop(app) == false else { return }
            self?.hideOtherApps(except: app, sweep: true)
        }
    }

    /// True when Finder is frontmost with no real window (bare desktop).
    private func isBareFinderDesktop(_ app: NSRunningApplication) -> Bool {
        guard app.bundleIdentifier == "com.apple.finder" else { return false }
        return focusableWindow(of: app) == nil
    }

    private func isStillFrontmost(_ app: NSRunningApplication) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }

    // MARK: - Intra-app window tracking

    private func observeWindows(of app: NSRunningApplication) {
        stopObservingWindows()

        let pid = app.processIdentifier
        var observer: AXObserver?
        guard AXObserverCreate(pid, focusFillAXCallback, &observer) == .success,
              let observer else {
            Logger.log("OBSERVE: AXObserverCreate failed for \(app.localizedName ?? "")")
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var watched = 0
        for note in [
            kAXFocusedWindowChangedNotification,
            kAXWindowCreatedNotification,
            kAXUIElementDestroyedNotification,
        ] {
            if AXObserverAddNotification(observer, appElement, note as CFString, refcon) == .success {
                watched += 1
            }
        }
        guard watched > 0 else {
            Logger.log("OBSERVE: no window notifications for \(app.localizedName ?? "")")
            return
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        windowObserver = observer
        observedPID = pid
    }

    private func stopObservingWindows() {
        if let observer = windowObserver {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
            windowObserver = nil
        }
        observedPID = -1
    }

    fileprivate func windowEventFired() {
        // Burst-coalescing: AX can fire several notifications per change.
        windowEventGen += 1
        let generation = windowEventGen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, generation == self.windowEventGen else { return }
            guard let frontmost = NSWorkspace.shared.frontmostApplication,
                  frontmost.activationPolicy == .regular,
                  frontmost.processIdentifier == self.observedPID,
                  PermissionsManager.shared.checkForAccessibilityPermissions()
            else { return }
            self.handleWindowEvent(for: frontmost)
        }
    }

    /// Re-evaluate dim/fill after a window opened, closed, or changed focus
    /// inside the already-frontmost app. Unlike the activation path, the event
    /// tells us state just changed, so a missing window hides immediately
    /// instead of going through slow-activation retries.
    private func handleWindowEvent(for app: NSRunningApplication) {
        guard focusableWindow(of: app) != nil else {
            Logger.log("EVENT: no window for \(app.localizedName ?? "") - hiding dim")
            hideDim()
            return
        }
        fillFocusedWindow(of: app, attempt: 1)
    }

    /// Focused/main element, but only when it is a real window. Finder with
    /// no windows exposes the desktop icon view (AXScrollArea) as its focused
    /// element - treating that as a window dims the bare desktop.
    private func focusableWindow(of app: NSRunningApplication) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let candidate = (appElement.getAttribute(.focusedWindow) as AXUIElement?)
            ?? (appElement.getAttribute(.mainWindow) as AXUIElement?)
        guard let candidate else { return nil }
        guard candidate.role == kAXWindowRole else {
            Logger.log(
                "NON-WINDOW: \(app.localizedName ?? "") role=\(candidate.role ?? "?")" +
                    " subrole=\(candidate.subrole ?? "?") - ignoring"
            )
            return nil
        }
        return candidate
    }

    private func hideOtherApps(except focusedApp: NSRunningApplication, sweep: Bool = false) {
        for other in NSWorkspace.shared.runningApplications
            where other.activationPolicy == .regular
            && other.processIdentifier != focusedApp.processIdentifier
            && !other.isHidden {
            // NOTE: hide() return value and an immediate isHidden read are
            // both unreliable, so neither is logged as a result here.
            _ = other.hide()
            Logger.log("\(sweep ? "RE-HIDE" : "HIDE"): \(other.localizedName ?? "")")
        }
    }

    private func fillFocusedWindow(of app: NSRunningApplication, attempt: Int) {
        guard let window = focusableWindow(of: app) else {
            // Finder with no windows means the bare desktop is focused.
            // Undim immediately instead of leaving the previous app's
            // dim up through the retries.
            if app.bundleIdentifier == "com.apple.finder" {
                hideDim()
            }
            guard attempt < 3 else {
                Logger.log("No focusable window for \(app.localizedName ?? "") - hiding dim")
                hideDim()
                return
            }
            Logger.log("No focusable window for \(app.localizedName ?? "") - retry \(attempt)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                // Only retry if the app is still frontmost
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return }
                self?.fillFocusedWindow(of: app, attempt: attempt + 1)
            }
            return
        }

        if window.isMinimized {
            window.minimize(false)
        }

        Logger.log(
            "WINDOW: \(app.localizedName ?? "") role=\(window.role ?? "?")" +
                " subrole=\(window.subrole ?? "?") title=\(window.title ?? "?")" +
                " frame=\(window.frame.map { "\($0)" } ?? "?")"
        )

        guard let screen = currentScreen(for: window) else { return }
        DimOverlay.shared.show(on: screen)

        let visible = screen.normalizedVisibleFrame
        let target = visible.insetBy(dx: fillMargin, dy: fillMargin)

        // Known fixed-size app: centre its natural size, no fill attempt.
        if let bundleId = app.bundleIdentifier, fixedSizeApps.contains(bundleId) {
            // Self-healing: if it ever shows up already filled, it has
            // clearly learned to resize - drop it from the cache.
            if let current = window.frame, current.approximatelyEqual(to: target, tolerance: 2) {
                forgetFixedSize(bundleId)
                armWatchdog(frame: current, pid: app.processIdentifier)
                return
            }
            if let final = centre(window: window, in: visible, appName: app.localizedName, cached: true) {
                armWatchdog(frame: final, pid: app.processIdentifier)
            }
            return
        }

        // Skip if already filled (avoid jitter / resize loops)
        if let current = window.frame, current.approximatelyEqual(to: target, tolerance: 2) {
            armWatchdog(frame: current, pid: app.processIdentifier)
            return
        }

        Logger.log("FILL: \(app.localizedName ?? "") -> \(target)")
        let originalSize = window.frame?.size
        app.runWithoutAnimations {
            window.setSize(target.size)
            window.setPosition(target.origin)
            // Set twice: some apps only respect position after size change
            window.setSize(target.size)
            window.setPosition(target.origin)
        }

        // Verify: fixed-size windows (e.g. Settings) refuse the resize.
        // Like native Centre (Fn-Ctrl-C), restore their original size
        // and leave them in the middle instead of half-stretched.
        // The refusal is remembered so next focus goes straight to centre.
        let finalFrame: CGRect
        if let actual = window.frame, !actual.sizeMatches(target, tolerance: 4),
           let originalSize {
            if let bundleId = app.bundleIdentifier {
                rememberFixedSize(bundleId)
            }
            window.setSize(originalSize)
            let centred = CGPoint(
                x: visible.midX - originalSize.width / 2,
                y: visible.midY - originalSize.height / 2
            )
            window.setPosition(centred)
            Logger.log("CENTRE: \(app.localizedName ?? "") -> \(centred)")
            finalFrame = CGRect(origin: centred, size: originalSize)
        } else {
            finalFrame = target
        }
        armWatchdog(frame: finalFrame, pid: app.processIdentifier)
    }

    /// Centres the window, returning its final frame (nil if unknown).
    private func centre(window: AXUIElement, in visible: CGRect, appName: String?, cached: Bool) -> CGRect? {
        guard let size = window.frame?.size else { return nil }

        let centred = CGPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )

        if let current = window.frame,
           abs(current.origin.x - centred.x) <= 2,
           abs(current.origin.y - centred.y) <= 2 {
            return current
        }

        window.setPosition(centred)
        Logger.log("CENTRE\(cached ? " (cached)" : ""): \(appName ?? "") -> \(centred)")
        return CGRect(origin: centred, size: size)
    }

    private func rememberFixedSize(_ bundleId: String) {
        fixedSizeApps.insert(bundleId)
        UserDefaults.standard.set(Array(fixedSizeApps), forKey: fixedSizeDefaultsKey)
    }

    private func forgetFixedSize(_ bundleId: String) {
        fixedSizeApps.remove(bundleId)
        UserDefaults.standard.set(Array(fixedSizeApps), forKey: fixedSizeDefaultsKey)
    }

    private func currentScreen(for window: AXUIElement) -> NSScreen? {
        let displayName = window.frame?.getDisplay()
        return displayName.flatMap(NSScreen.screen) ?? NSScreen.main
    }

    // MARK: - Dim + watchdog

    private func hideDim() {
        DimOverlay.shared.hide()
        disarmWatchdog()
    }

    private func armWatchdog(frame: CGRect?, pid: pid_t) {
        guard let frame else { return }
        lastFilledFrame = frame
        lastFilledPID = pid
        watchdogConcealed = false
        guard watchdogTimer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.watchdogFired()
        }
        // common modes: keep firing during gesture tracking, so the dim
        // hides mid-spread instead of after it.
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
    }

    private func disarmWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        lastFilledFrame = nil
        lastFilledPID = nil
        watchdogConcealed = false
    }

    private func watchdogFired() {
        guard let frame = lastFilledFrame, let pid = lastFilledPID else {
            disarmWatchdog()
            return
        }
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.activationPolicy == .regular
        else { return }
        guard frontmost.processIdentifier == pid else {
            // Focus moved on; the activation path owns the dim now.
            disarmWatchdog()
            return
        }

        if isFrameOnScreen(frame, pid: pid) {
            if watchdogConcealed {
                guard let screen = NSScreen.screen(frame.getDisplay()) ?? NSScreen.main else { return }
                Logger.log("WATCHDOG: window back on screen - re-showing dim")
                DimOverlay.shared.show(on: screen)
                watchdogConcealed = false
            }
        } else if !watchdogConcealed {
            // CG mismatch: either the compositor moved the window
            // (Show Desktop / Exposé / minimize -> hide the dim) or the
            // user moved/resized it (AX model changed -> keep dim, re-track).
            if let app = NSRunningApplication(processIdentifier: pid),
               let axFrame = focusableWindow(of: app)?.frame,
               !axFrame.approximatelyEqual(to: frame, tolerance: 4) {
                Logger.log("WATCHDOG: window moved/resized - re-tracking \(axFrame)")
                lastFilledFrame = axFrame
            } else {
                Logger.log("WATCHDOG: filled window off screen - hiding dim")
                DimOverlay.shared.hide()
                watchdogConcealed = true
            }
        }
    }

    /// True when a normal-layer on-screen window of pid matches frame.
    /// CGWindowList bounds share AX's top-left coordinate space (verified).
    /// Fail-open: on API failure report visible so we never hide wrongly.
    private func isFrameOnScreen(_ frame: CGRect, pid: pid_t) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]]
        else { return true }
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? Int32) == pid else { continue }
            guard ((info[kCGWindowLayer as String] as? Int) ?? 0) >= 0 else { continue }
            guard let rawBounds = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: rawBounds as CFDictionary)
            else { continue }
            if bounds.approximatelyEqual(to: frame, tolerance: 4) { return true }
        }
        return false
    }
}

private extension CGRect {
    func approximatelyEqual(to other: CGRect, tolerance: CGFloat) -> Bool {
        abs(origin.x - other.origin.x) <= tolerance &&
            abs(origin.y - other.origin.y) <= tolerance &&
            sizeMatches(other, tolerance: tolerance)
    }

    func sizeMatches(_ other: CGRect, tolerance: CGFloat) -> Bool {
        abs(size.width - other.size.width) <= tolerance &&
            abs(size.height - other.size.height) <= tolerance
    }
}

// MARK: - AXObserver callback (file scope: C function pointer, no captures)

private func focusFillAXCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let manager = Unmanaged<FocusFillManager>.fromOpaque(refcon).takeUnretainedValue()
    manager.windowEventFired()
}
