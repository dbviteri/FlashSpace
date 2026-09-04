//
//  AppDelegate.swift
//

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDependencies.shared.focusFillManager.start()
    }
}
