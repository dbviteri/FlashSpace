//
//  NSScreen.swift
//
//  Created by Wojciech Kulik on 18/03/2025.
//  Copyright © 2025 Wojciech Kulik. All rights reserved.
//

import AppKit

extension NSScreen {
    /// Returns the screen's frame where (x,y) is top-left corner relative
    /// to the main screen's top-left corner.
    var normalizedFrame: CGRect {
        let mainScreen = NSScreen.screens[0]
        return NSRect(
            x: frame.origin.x,
            y: mainScreen.frame.height - frame.origin.y - frame.height,
            width: frame.width,
            height: frame.height
        )
    }

    /// visibleFrame converted to AX coordinates where (0,0) is the
    /// top-left corner relative to the main screen's top-left corner.
    var normalizedVisibleFrame: CGRect {
        let mainScreen = NSScreen.screens[0]
        return NSRect(
            x: visibleFrame.origin.x,
            y: mainScreen.frame.height - visibleFrame.origin.y - visibleFrame.height,
            width: visibleFrame.width,
            height: visibleFrame.height
        )
    }

    static func isConnected(_ display: DisplayName) -> Bool {
        NSScreen.screens.contains { $0.localizedName == display }
    }

    static func screen(_ display: DisplayName?) -> NSScreen? {
        NSScreen.screens.first { $0.localizedName == display }
    }
}
