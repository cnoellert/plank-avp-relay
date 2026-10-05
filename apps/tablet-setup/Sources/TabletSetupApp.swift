// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import RelaySetupKit

@main
struct TabletSetupApp: App {
    var body: some Scene {
        WindowGroup {
            TabletSetupView()

        }
        .defaultSize(width: 820, height: 760)
    }
}
