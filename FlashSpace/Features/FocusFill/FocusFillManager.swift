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

        hideOtherApps(except: app)

        // Small delay: the newly activated window may not be ready via AX yet
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.fillFocusedWindow(of: app, attempt: 1)
        }

        // Delayed sweep: catch apps that reappeared or were missed
        // (e.g. slow-activating apps like Chrome unhiding late)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.hideOtherApps(except: app, sweep: true)
        }
    }

    private func hideOtherApps(except focusedApp: NSRunningApplication, sweep: Bool = false) {
        for other in NSWorkspace.shared.runningApplications
            where other.activationPolicy == .regular
            && other.processIdentifier != focusedApp.processIdentifier
            && !other.isHidden {
            // NOTE: hide() return value is unreliable (returns NO even on
            // success on recent macOS), so it is intentionally ignored.
            _ = other.hide()
            Logger.log(
                "\(sweep ? "RE-HIDE" : "HIDE"): \(other.localizedName ?? "")" +
                    ", isHidden now: \(other.isHidden)"
            )
        }
    }

    private func fillFocusedWindow(of app: NSRunningApplication, attempt: Int) {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let window: AXUIElement? =
            (appElement.getAttribute(.focusedWindow) as AXUIElement?)
                ?? (appElement.getAttribute(.mainWindow) as AXUIElement?)

        guard let window else {
            guard attempt < 3 else {
                Logger.log("No focusable window for \(app.localizedName ?? "") - giving up")
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
                return
            }
            centre(window: window, in: visible, appName: app.localizedName, cached: true)
            return
        }

        // Skip if already filled (avoid jitter / resize loops)
        if let current = window.frame, current.approximatelyEqual(to: target, tolerance: 2) {
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
        }
    }

    private func centre(window: AXUIElement, in visible: CGRect, appName: String?, cached: Bool) {
        guard let size = window.frame?.size else { return }

        let centred = CGPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )

        if let current = window.frame,
           abs(current.origin.x - centred.x) <= 2,
           abs(current.origin.y - centred.y) <= 2 {
            return
        }

        window.setPosition(centred)
        Logger.log("CENTRE\(cached ? " (cached)" : ""): \(appName ?? "") -> \(centred)")
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
