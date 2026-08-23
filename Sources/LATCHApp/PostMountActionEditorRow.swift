import LATCHShared
import SwiftUI

struct PostMountActionEditorRow: View {
    @Binding var action: PostMountAction

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch action {
            case .revealInFinder:
                Text("Reveal the mounted volume in Finder.")
                    .foregroundStyle(.secondary)
            case .openApplication:
                TextField("Bundle identifier", text: applicationBinding(\.bundleIdentifier))
                TextField("Application path hint (optional)", text: Binding(
                    get: { applicationValue.applicationURL ?? "" },
                    set: { value in
                        let application = applicationValue
                        action = .openApplication(bundleIdentifier: application.bundleIdentifier, applicationURL: value.isEmpty ? nil : value)
                    }
                ))
                Text("The agent verifies the selected .app bundle's identifier before opening it.")
                    .font(.caption).foregroundStyle(.secondary)
            case .openRelativePath:
                TextField("Path below mounted volume", text: Binding(
                    get: { relativePath },
                    set: { action = .openRelativePath($0) }
                ))
                Text("Use . for the volume root. Paths cannot leave the mounted volume.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private var applicationValue: (bundleIdentifier: String, applicationURL: String?) {
        guard case .openApplication(let bundleIdentifier, let applicationURL) = action else { return ("", nil) }
        return (bundleIdentifier, applicationURL)
    }

    private var relativePath: String {
        guard case .openRelativePath(let path) = action else { return "" }
        return path
    }

    private func applicationBinding(_ keyPath: WritableKeyPath<(bundleIdentifier: String, applicationURL: String?), String>) -> Binding<String> {
        Binding(
            get: { applicationValue[keyPath: keyPath] },
            set: { value in
                let application = applicationValue
                action = .openApplication(bundleIdentifier: value, applicationURL: application.applicationURL)
            }
        )
    }
}
