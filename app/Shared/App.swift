import SwiftUI

@main
struct AppMain: App {
    /// UI test override: when launched with `-UITestColorScheme light` or
    /// `-UITestColorScheme dark`, force the SwiftUI scene's preferred color
    /// scheme. Used by AppStoreScreenshotTests to capture light + dark
    /// appearance screenshots WITHOUT calling `XCUIDevice.shared.appearance`,
    /// which has a known cold-simulator timeout flake on GHA macOS runners
    /// (the setter waits for springboard confirmation; on freshly-booted
    /// simulators the confirmation handshake can timeout ~5-10% of runs).
    /// Real users never pass `-UITestColorScheme`, so this is a no-op
    /// outside UI tests — the system's own light/dark preference wins.
    private let forcedColorScheme: ColorScheme? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-UITestColorScheme"),
              i + 1 < args.count else { return nil }
        switch args[i + 1] {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(forcedColorScheme)
        }
    }
}
