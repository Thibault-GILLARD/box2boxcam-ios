import SwiftUI

@main
@MainActor
struct PitchLensDockKitApp: App {
    // @State, not @StateObject: the root must not re-render at analysis rate.
    @State private var model = DockKitModel()
    var body: some Scene {
        WindowGroup { RootView(model: model) }
    }
}
