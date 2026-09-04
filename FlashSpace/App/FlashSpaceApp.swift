//
//  FlashSpaceApp.swift
//  FlashSpace
//

import SwiftUI

@main
struct FlashSpaceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("⚡ FlashSpace", systemImage: "rectangle.fill.on.rectangle.fill") {
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }
}
