import SwiftUI

@main
struct ConductorMobileApp: App {
    @State private var api = APIClient()

    var body: some Scene {
        WindowGroup {
            ProjectsView()
                .environment(api)
                .preferredColorScheme(.dark)
        }
    }
}
