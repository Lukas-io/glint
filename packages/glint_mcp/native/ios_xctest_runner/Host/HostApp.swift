import SwiftUI

/// The app XCTest needs as a test host; glint never drives it.
@main
struct HostApp: App {
    var body: some Scene {
        WindowGroup { Text("glint runner") }
    }
}
