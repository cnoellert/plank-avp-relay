// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import RelaySetupKit

@main
struct TabletSetupApp: App {
    var body: some Scene {
        WindowGroup {
            TabletSetupView()
                // Launch-only entry used by PLANK's "Set up a Relay…". The URL
                // carries no parameters and none are read: opening Setup never
                // selects, approves or configures anything by itself.
                .onOpenURL { _ in }
        }
        .defaultSize(width: 820, height: 760)
    }
}
