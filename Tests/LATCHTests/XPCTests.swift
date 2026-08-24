import Foundation
import Testing
@testable import LATCHShared

@Suite("XPC envelope validation")
struct XPCTests {
    @Test func statusSinkDecodesLegacyStatusPayloads() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let status = MountStatus(
            definitionID: UUID(),
            observedSource: "nas.local:/media",
            observedMountPoint: "/Volumes/Media",
            state: .healthy,
            lastProbe: date,
            lastStateChange: date,
            lastHealthyTime: date,
            lastRecoveryTime: nil,
            detail: "Healthy",
            errorCode: .none
        )
        let data = try JSONEncoder().encode([status])

        #expect(try LATCHStatusSinkCodec.decode(data) == .statuses([status]))
    }

    @Test func statusSinkDeliversLiveActivityPayloads() throws {
        let event = LATCHEvent(
            date: Date(timeIntervalSince1970: 1_800_000_000),
            mountID: UUID(),
            state: .networkUnavailable,
            code: .networkUnavailable,
            detail: "The server is unavailable."
        )

        let data = try LATCHStatusSinkCodec.encodeEvents([event])

        #expect(try LATCHStatusSinkCodec.decode(data) == .events([event]))
    }

    @Test func statusSinkDeliversRevisionedRuntimeSnapshots() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let status = MountStatus(
            definitionID: UUID(),
            observedSource: "nas.local:/media",
            observedMountPoint: "/Volumes/Media",
            state: .healthy,
            lastProbe: date,
            lastStateChange: date,
            lastHealthyTime: date,
            lastRecoveryTime: nil,
            detail: "Healthy",
            errorCode: .none
        )
        let event = LATCHEvent(
            date: date,
            mountID: status.id,
            state: .healthy,
            code: .none,
            detail: "Healthy"
        )
        let snapshot = LATCHRuntimeSnapshot(revision: 42, statuses: [status], events: [event])

        let data = try LATCHStatusSinkCodec.encodeRuntime(snapshot)

        #expect(data.count <= XPCCodec.maximumMessageBytes)
        #expect(try LATCHStatusSinkCodec.decode(data) == .runtime(snapshot))
    }

    @Test func statusSinkRejectsOversizedCombinedRuntimeSnapshots() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let event = LATCHEvent(
            date: date,
            mountID: UUID(),
            state: .probeError,
            code: .verificationFailed,
            detail: String(repeating: "x", count: XPCCodec.maximumMessageBytes)
        )

        #expect(throws: XPCValidationError.oversized) {
            _ = try LATCHStatusSinkCodec.encodeRuntime(
                LATCHRuntimeSnapshot(revision: 1, statuses: [], events: [event])
            )
        }
    }

    @Test func agentRequestsUseDeadlinesThatMatchTheirSideEffects() {
        #expect(AgentRequestDeadline.category(for: .probe(mountPoint: "/tmp/share", timeoutSeconds: 3)) == .probe)
        #expect(AgentRequestDeadline.timeout(for: .probe(mountPoint: "/tmp/share", timeoutSeconds: 3)) == .seconds(5))
        let app = MacApplicationDependency(bundleIdentifier: "com.example.App", applicationURL: nil, forceQuitAfterTimeout: true)
        #expect(AgentRequestDeadline.category(for: .stop(app, timeoutSeconds: 8)) == .dependency)
        #expect(AgentRequestDeadline.timeout(for: .stop(app, timeoutSeconds: 8)) == .seconds(18))
        let delivery = PostMountActionDelivery(mountID: UUID(), source: "server:/share", mountPoint: "/tmp/share", actions: [])
        #expect(AgentRequestDeadline.category(for: .executePostMountActions(delivery)) == .postMount)
        #expect(AgentRequestDeadline.category(for: .revealManagedMount(mountPoint: "/tmp/share")) == .reveal)
    }

    @Test func agentRequestDeadlineInvalidatesANeverReplyingTransport() async {
        let invalidated = LockedBoolean()

        await #expect(throws: ResponseDeadlineError.timedOut) {
            let _: AgentResponse = try await AgentRequestDeadline.wait(
                for: .probe(mountPoint: "/tmp/share", timeoutSeconds: 3),
                timeoutOverride: .milliseconds(20),
                onTimeout: { invalidated.setTrue() }
            ) { _ in }
        }

        #expect(invalidated.value)
    }

    @Test func cancelledAgentSideEffectIsNotDispatched() async {
        let requester = RecordingAgentRequester(response: .succeeded)
        let cancellation = MountOperationCancellation(isCancelled: { true })

        await #expect(throws: MountOperationCancellationError.cancelled) {
            _ = try await requester.request(
                .revealManagedMount(mountPoint: "/tmp/share"),
                cancellation: cancellation
            )
        }

        #expect(await requester.lastRequest == nil)
    }

    @Test func currentAgentSideEffectDelegatesToTheUnderlyingRequester() async throws {
        let request = AgentRequest.revealManagedMount(mountPoint: "/tmp/share")
        let requester = RecordingAgentRequester(response: .succeeded)

        let response = try await requester.request(request, cancellation: .never)

        #expect(response == .succeeded)
        #expect(await requester.lastRequest == request)
    }

    @Test func firstAgentRegistrationRequestsAnImmediateHealthCheck() {
        var availability = AgentConnectionAvailability()

        let shouldCheck = availability.register()
        #expect(shouldCheck)
    }

    @Test func periodicAgentRegistrationDoesNotRepeatTheImmediateHealthCheck() {
        var availability = AgentConnectionAvailability()
        _ = availability.register()

        let shouldCheck = availability.register()
        #expect(!shouldCheck)
    }

    @Test func agentReconnectionRequestsAnotherImmediateHealthCheck() {
        var availability = AgentConnectionAvailability()
        _ = availability.register()
        availability.disconnect()

        let shouldCheck = availability.register()
        #expect(shouldCheck)
    }

    @Test func serviceStatusRoundTripPreservesAgentConnectivity() throws {
        let expected = ServiceStatusSnapshot(
            daemonOnline: true,
            daemonAuthorized: true,
            agentAuthorized: true,
            agentOnline: false,
            networkVolumesVerification: .verified
        )

        let response = LATCHResponse.serviceStatus(expected)
        let data = try XPCCodec.encodeResponse(response, requestID: UUID())

        #expect(try JSONDecoder().decode(XPCResponseEnvelope.self, from: data).response == response)
    }

    @Test func responseDecodingValidatesRequestIDAndVersion() throws {
        let requestID = UUID()
        let response = LATCHResponse.serviceStatus(
            ServiceStatusSnapshot(
                daemonOnline: true,
                daemonAuthorized: true,
                agentAuthorized: true,
                agentOnline: true,
                networkVolumesVerification: .verified
            )
        )
        let valid = try XPCCodec.encodeResponse(response, requestID: requestID)
        #expect(try XPCCodec.decodeResponse(valid, expectedRequestID: requestID) == response)
        #expect(throws: XPCValidationError.unsupportedVersion) {
            let envelope = XPCResponseEnvelope(version: 99, requestID: requestID, response: response)
            let data = try JSONEncoder().encode(envelope)
            _ = try XPCCodec.decodeResponse(data, expectedRequestID: requestID)
        }
        #expect(throws: XPCValidationError.malformed) {
            _ = try XPCCodec.decodeResponse(Data("{".utf8), expectedRequestID: requestID)
        }
        #expect(throws: XPCValidationError.mismatchedRequestID) {
            let wrongID = UUID()
            let data = try XPCCodec.encodeResponse(response, requestID: wrongID)
            _ = try XPCCodec.decodeResponse(data, expectedRequestID: requestID)
        }
        #expect(throws: XPCValidationError.oversized) {
            let data = Data(repeating: 0, count: XPCCodec.maximumMessageBytes + 1)
            _ = try XPCCodec.decodeResponse(data, expectedRequestID: requestID)
        }
    }

    @Test @MainActor func daemonClientHandlesXPCRepliesDeliveredOffTheMainActor() async {
        let client = LATCHDaemonRequestClient(
            signingRequirement: "identifier \"invalid.latch.test.identity\"",
            responseTimeout: .milliseconds(100)
        )

        _ = try? await client.request(.getStatus)
    }

    @Test func daemonClientRejectsMismatchedRequestIDInjectedResponse() async {
        let client = LATCHDaemonRequestClient(
            signingRequirement: "identifier \"invalid.latch.test.identity\"",
            responseTimeout: .seconds(1),
            transport: { requestData, _ in
                let envelope = try JSONDecoder().decode(XPCRequestEnvelope.self, from: requestData)
                var wrongID = UUID()
                while wrongID == envelope.requestID {
                    wrongID = UUID()
                }
                return try XPCCodec.encodeResponse(.accepted, requestID: wrongID)
            }
        )

        await #expect(throws: XPCValidationError.mismatchedRequestID) {
            _ = try await client.request(.getStatus)
        }
    }

    @Test func daemonClientRejectsOversizedInjectedResponse() async {
        let client = LATCHDaemonRequestClient(
            signingRequirement: "identifier \"invalid.latch.test.identity\"",
            responseTimeout: .seconds(1),
            transport: { _, _ in
                return Data(repeating: 0, count: XPCCodec.maximumMessageBytes + 1)
            }
        )

        await #expect(throws: XPCValidationError.oversized) {
            _ = try await client.request(.getStatus)
        }
    }

    @Test func daemonClientRejectsUnsupportedVersionInjectedResponse() async throws {
        let requestID = UUID()
        let response = LATCHResponse.serviceStatus(
            ServiceStatusSnapshot(
                daemonOnline: true,
                daemonAuthorized: true,
                agentAuthorized: true,
                agentOnline: true,
                networkVolumesVerification: .verified
            )
        )
        let data = try JSONEncoder().encode(XPCResponseEnvelope(version: 99, requestID: requestID, response: response))
        let client = LATCHDaemonRequestClient(
            signingRequirement: "identifier \"invalid.latch.test.identity\"",
            responseTimeout: .seconds(1),
            transport: { _, _ in return data }
        )

        await #expect(throws: XPCValidationError.unsupportedVersion) {
            _ = try await client.request(.getStatus)
        }
    }

    @Test func validRequestRoundTrips() throws {
        let request = LATCHRequest.getStatus
        let data = try XPCCodec.encodeRequest(request)
        #expect(try XPCCodec.decodeRequest(data) == request)
    }

    @Test func clearActivityRequestRoundTrips() throws {
        let request = LATCHRequest.clearEvents
        let data = try XPCCodec.encodeRequest(request)

        #expect(try XPCCodec.decodeRequest(data) == request)
    }

    @Test func clearActivityReportsPersistenceFailureInsteadOfAcceptingIt() {
        #expect(ActivityClearResponse.response(persisted: true) == .accepted)
        #expect(ActivityClearResponse.response(persisted: false) == .failure(
            .persistenceFailed,
            "Recent activity could not be cleared because the change could not be saved."
        ))
    }

    @Test func serverCRUDRequestsRoundTrip() throws {
        let server = NFSServerProfile(name: "NAS", hostname: "nas.local", networkMountRules: .init(rules: [.nfsServiceReachable]))

        #expect(try XPCCodec.decodeRequest(XPCCodec.encodeRequest(.saveServer(server))) == .saveServer(server))
        #expect(try XPCCodec.decodeRequest(XPCCodec.encodeRequest(.removeServer(server.id))) == .removeServer(server.id))
    }

    @Test func manualWakeRequestRoundTrips() throws {
        let serverID = UUID()
        let request = LATCHRequest.wakeServer(serverID)

        #expect(try XPCCodec.decodeRequest(XPCCodec.encodeRequest(request)) == request)
    }

    @Test func operationRequestsRoundTrip() throws {
        let operationID = UUID()

        #expect(try XPCCodec.decodeRequest(XPCCodec.encodeRequest(.getOperations)) == .getOperations)
        #expect(try XPCCodec.decodeRequest(XPCCodec.encodeRequest(.getOperation(operationID))) == .getOperation(operationID))
        #expect(try XPCCodec.decodeRequest(XPCCodec.encodeRequest(.cancelOperation(operationID))) == .cancelOperation(operationID))
    }

    @Test func operationSnapshotsRoundTrip() throws {
        let receipt = OperationReceipt(id: UUID(), mountID: UUID(), action: .mount, startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let accepted = LATCHResponse.operationAccepted(receipt)
        let acceptedData = try XPCCodec.encodeResponse(accepted, requestID: UUID())
        #expect(try JSONDecoder().decode(XPCResponseEnvelope.self, from: acceptedData).response == accepted)

        let snapshot = OperationSnapshot(
            id: receipt.id,
            mountID: receipt.mountID,
            action: receipt.action,
            state: .running,
            canCancel: true,
            detail: "Mounting the configured NFS volume.",
            updatedAt: Date(timeIntervalSince1970: 1_800_000_001)
        )
        let response = LATCHResponse.operationSnapshot(snapshot)
        let data = try XPCCodec.encodeResponse(response, requestID: UUID())
        #expect(try JSONDecoder().decode(XPCResponseEnvelope.self, from: data).response == response)

        let collection = LATCHResponse.operationSnapshots([snapshot])
        let collectionData = try XPCCodec.encodeResponse(collection, requestID: UUID())
        #expect(try JSONDecoder().decode(XPCResponseEnvelope.self, from: collectionData).response == collection)
    }

    @Test func discoveredServerSnapshotsRoundTrip() throws {
        let expected = [DiscoveredNFSServer(name: "Media", hostname: "nas.local", port: 2049)]
        let response = LATCHResponse.discoveredServers(expected)
        let data = try XPCCodec.encodeResponse(response, requestID: UUID())
        #expect(try JSONDecoder().decode(XPCResponseEnvelope.self, from: data).response == response)
    }

    @Test func atomicServerAndMountSaveRequestRoundTrips() throws {
        let server = NFSServerProfile(name: "NAS", hostname: "nas.local")
        let mount = MountDefinition(displayName: "Media", serverID: server.id, exportPath: "/media", mountPoint: "/Volumes/Media/Media")

        #expect(try XPCCodec.decodeRequest(XPCCodec.encodeRequest(.saveServerAndDefinition(server, mount))) == .saveServerAndDefinition(server, mount))
    }

    @Test func portableConfigurationRequestsAndPreviewResponsesRoundTripWithinTheMessageLimit() throws {
        let payload = try PortableConfigurationCodec.export(.init())
        let request = LATCHRequest.previewPortableConfiguration(payload)
        let preview = PortableImportPreview(items: [.init(kind: .server, id: UUID(), title: "NAS", disposition: .addition)])

        #expect(try XPCCodec.decodeRequest(XPCCodec.encodeRequest(request)) == request)
        let response = LATCHResponse.portableConfigurationPreview(preview)
        let data = try XPCCodec.encodeResponse(response, requestID: UUID())
        #expect(data.count <= XPCCodec.maximumMessageBytes)
        #expect(try JSONDecoder().decode(XPCResponseEnvelope.self, from: data).response == response)
    }

    @Test func userProbeRequestRoundTrips() throws {
        let request = AgentRequest.probe(mountPoint: "/Users/test/Music", timeoutSeconds: 7)
        #expect(try AgentCodec.decode(AgentCodec.encode(request)) == request)
    }

    @Test func dependencyAgentRequestsRoundTrip() throws {
        let dependency = RecoveryDependency(
            id: UUID(),
            enabled: true,
            stopTimeoutSeconds: 12,
            kind: .dockerContainer(
                DockerContainerDependency(
                    containerName: "media-server",
                    dockerSocketPath: "/var/run/docker.sock",
                    composeFilePath: "/tmp/compose.yml"
                )
            )
        )
        let requests: [AgentRequest] = [
            .dependencyPrepare(dependency),
            .dependencyIsRunning(dependency),
            .dependencyStop(dependency, timeoutSeconds: 12),
            .dependencyStart(dependency),
            .dependencyVerifyRunning(dependency, timeoutSeconds: 30)
        ]

        for request in requests {
            #expect(try AgentCodec.decode(AgentCodec.encode(request)) == request)
        }
    }

    @Test func applicationAgentRequestsCarryTheExpectedBundleURL() throws {
        let app = MacApplicationDependency(
            bundleIdentifier: "com.example.Player",
            applicationURL: "/Applications/Player.app",
            forceQuitAfterTimeout: true
        )
        let requests: [AgentRequest] = [
            .isRunning(app),
            .stop(app, timeoutSeconds: 10),
            .start(app),
            .verifyRunning(app, timeoutSeconds: 30),
        ]

        for request in requests {
            #expect(try AgentCodec.decode(AgentCodec.encode(request)) == request)
        }
    }

    @Test func userProbeRunnerReturnsTheAgentsProbeResult() async {
        let expected = ProbeResult(directoryErrno: EACCES, failedOperation: .directoryOpen)
        let requester = RecordingAgentRequester(response: .probe(expected))
        let runner = AgentProbeRunner(requester: requester)

        let result = await runner.run(mountPoint: "/Users/test/Music", timeoutSeconds: 7)

        #expect(result == expected)
        #expect(await requester.lastRequest == .probe(mountPoint: "/Users/test/Music", timeoutSeconds: 7))
    }

    @Test func unavailableUserAgentKeepsAMountedVolumeWaitingForItsHealthCheck() async {
        let runner = AgentProbeRunner(requester: FailingAgentRequester())

        let result = await runner.run(mountPoint: "/Users/test/Music", timeoutSeconds: 7)

        #expect(result.executionUnavailable == true)
        #expect(result.metadataErrno == nil)
        #expect(result.failedOperation == nil)
        #expect(ProbeClassifier.classify(result).state == .mounting)
    }

    @Test func siblingHelperPathUsesTheAbsoluteRunningExecutableLocation() {
        let executable = ExecutableLocation.current
        let sibling = ExecutableLocation.sibling(named: "LATCHProbe")

        #expect(executable.path.hasPrefix("/"))
        #expect(FileManager.default.fileExists(atPath: executable.path))
        #expect(sibling.deletingLastPathComponent() == executable.deletingLastPathComponent())
        #expect(sibling.lastPathComponent == "LATCHProbe")
    }

    @Test func oversizedRequestIsRejectedBeforeDecode() {
        let data = Data(repeating: 0, count: XPCCodec.maximumMessageBytes + 1)
        #expect(throws: XPCValidationError.oversized) {
            try XPCCodec.decodeRequest(data)
        }
    }

    @Test func unsupportedVersionIsRejected() throws {
        let envelope = XPCRequestEnvelope(version: 99, requestID: UUID(), request: .getStatus)
        let data = try JSONEncoder().encode(envelope)
        #expect(throws: XPCValidationError.unsupportedVersion) {
            try XPCCodec.decodeRequest(data)
        }
    }

    @Test func malformedJSONIsRejected() {
        #expect(throws: XPCValidationError.malformed) {
            try XPCCodec.decodeRequest(Data("{".utf8))
        }
    }

    @Test func unexpectedSigningIdentityIsRejected() {
        let policy = ClientSigningPolicy(teamID: "TEAM123", bundleIdentifiers: ["com.example.client"])
        #expect(policy.accepts(teamID: "OTHER", bundleIdentifier: "com.example.client") == false)
        #expect(policy.accepts(teamID: "TEAM123", bundleIdentifier: "other.app") == false)
        #expect(policy.accepts(teamID: "TEAM123", bundleIdentifier: "com.example.client"))
        #expect(policy.codeSigningRequirement.contains("certificate leaf[subject.OU] = \"TEAM123\""))
        #expect(policy.codeSigningRequirement.contains("identifier \"com.example.client\""))
    }
}

private actor RecordingAgentRequester: AgentRequesting {
    let response: AgentResponse
    var lastRequest: AgentRequest?

    init(response: AgentResponse) { self.response = response }

    func request(_ request: AgentRequest) async throws -> AgentResponse {
        lastRequest = request
        return response
    }
}

private struct FailingAgentRequester: AgentRequesting {
    func request(_ request: AgentRequest) async throws -> AgentResponse {
        throw TestAgentError.unavailable
    }
}

private enum TestAgentError: Error { case unavailable }

private final class LockedBoolean: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool { lock.withLock { storage } }

    func setTrue() {
        lock.withLock { storage = true }
    }
}
