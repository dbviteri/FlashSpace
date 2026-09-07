//
//  DimOverlay.swift
//
//  Replicates the native Window > Fill desktop dim: a click-through
//  black overlay sitting just below app windows, shown on the
//  focused window's screen every time focus changes.
//

import AppKit

final class DimOverlay {
    static let shared = DimOverlay()

    private let dimAlpha: CGFloat = 0.45
    private var window: NSWindow?

    private init() {}

    func show(on screen: NSScreen) {
        let overlay = window ?? makeWindow()
        overlay.setFrame(screen.frame, display: true)

        if !overlay.isVisible {
            overlay.alphaValue = 0
            overlay.orderFrontRegardless()
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            overlay.animator().alphaValue = dimAlpha
        }
    }

    func hide() {
        guard let overlay = window, overlay.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            overlay.animator().alphaValue = 0
        } completionHandler: {
            // Only order out if the fade wasn't superseded by a new show()
            if overlay.alphaValue == 0 {
                overlay.orderOut(nil)
            }
        }
    }

    private func makeWindow() -> NSWindow {
        let overlay = NSWindow(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        overlay.backgroundColor = .black
        overlay.isOpaque = false
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.animationBehavior = .none
        // Below normal app windows (level 0), above the desktop.
        overlay.level = NSWindow.Level(rawValue: -1)
        // stationary: pinned during Mission Control / Show Desktop so the
        // overlay never slides around as a "shadow". FocusFillManager hides
        // it via watchdog while the filled window is off screen.
        overlay.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window = overlay
        return overlay
    }
}
