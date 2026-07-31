import SwiftUI

@main
struct RunwayMobileApp: App {
    @State private var model = UsageCloudModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            DashboardView(model: model)
                .task { await model.refresh() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await model.refresh() }
                    }
                }
        }
    }
}
