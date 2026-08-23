import AppKit
import Foundation
import UniformTypeIdentifiers
import LATCHShared

@MainActor
extension AppModel {
    func exportDiagnostics() {
        do {
            let data = try DiagnosticExporter.make(
                configuration: configuration,
                statuses: statuses,
                events: events,
                externalMounts: externalMounts,
                serviceStatus: serviceStatus
            )
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "latch-diagnostics.json"
            panel.allowedContentTypes = [.json]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func exportConfiguration() {
        Task {
            do {
                guard case .portableConfiguration(let data) = try await send(.exportPortableConfiguration) else {
                    throw AppModelError.daemonUnavailable
                }
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "latch-configuration.latchconfig"
                panel.allowedContentTypes = [.latchConfiguration]
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try data.write(to: url, options: [.atomic])
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func importConfiguration() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.latchConfiguration]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let data = try Data(contentsOf: url)
                guard data.count <= PortableConfigurationCodec.maximumBytes else { throw PortableConfigurationError.oversized }
                guard case .portableConfigurationPreview(let preview) = try await send(.previewPortableConfiguration(data)) else {
                    throw AppModelError.daemonUnavailable
                }
                importedConfigurationData = data
                configurationImportPreview = preview
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func applyImportedConfiguration(serverIDs: Set<UUID>, mountIDs: Set<UUID>) {
        guard let data = importedConfigurationData else { return }
        Task {
            do {
                let response = try await send(.applyPortableConfiguration(data, approvedServerIDs: Array(serverIDs), approvedMountIDs: Array(mountIDs)))
                if case .failure(_, let detail) = response {
                    errorMessage = detail
                    return
                }
                importedConfigurationData = nil
                configurationImportPreview = nil
                await refresh()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func cancelConfigurationImport() {
        configurationImportPreview = nil
        importedConfigurationData = nil
    }

    func clearActivity() async {
        do {
            let response = try await send(.clearEvents)
            if case .failure(_, let detail) = response {
                errorMessage = detail
                return
            }
            events.removeAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private extension UTType {
    static let latchConfiguration = UTType(exportedAs: LATCHIdentity.configurationTypeIdentifier)
}
