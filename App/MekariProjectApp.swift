import MekariProjectFeatures
import MekariProjectKit
import SwiftUI

@main
struct MekariProjectApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Mekari Project") {
            HelloView(model: model)
        }
        .windowResizability(.contentMinSize)
    }
}

/// Scaffold placeholder; the App shell PR replaces it with sign-in and the main split view.
struct HelloView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checklist")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text(model.greeting)
                .font(.title)
        }
        .padding(40)
        .frame(minWidth: 480, minHeight: 320)
    }
}

#Preview {
    HelloView(model: AppModel())
}
