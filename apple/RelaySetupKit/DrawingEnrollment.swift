// SPDX-License-Identifier: GPL-3.0-or-later
import Combine
import Foundation

public struct DrawingRegistrationTarget: Sendable {
    public let displayName: String
    public let managementIdentity: String
    public let descriptor: DrawingDescriptor
}

@MainActor
public final class DrawingEnrollmentInbox: ObservableObject {
    public static let shared = DrawingEnrollmentInbox()
    @Published public private(set) var request: DrawingRegistrationRequest?
    @Published public private(set) var target: DrawingRegistrationTarget?
    @Published public var message = ""
    @Published public var busy = false
    private var seen = Set<String>()
    private var received: ContinuousClock.Instant?

    public func receive(_ url: URL) {
        guard url.host == "enroll" else { return } // Existing launch-only links stay inert.
        do {
            let incoming = try DrawingRegistrationRequest.parse(url)
            if incoming == request { return } // Reopening the pending sheet is not a new approval.
            guard !busy, request == nil, seen.count < 256 else { throw DrawingRegistrationError.invalidRequest }
            guard !seen.contains(incoming.requestID) else { throw DrawingRegistrationError.expired }
            try DrawingRegistrationReceipt.requirePending(incoming)
            let target = try DrawingHandoff.registrationTarget(incoming)
            seen.insert(incoming.requestID)
            request = incoming; self.target = target; received = .now
            message = "Register this Relay for drawing in PLANK? No tablet button sequence is needed."
        } catch { message = error.localizedDescription }
    }
    public var live: Bool {
        guard let received else { return false }
        return ContinuousClock.now < received + .seconds(120)
    }
    public func dismiss(removeReceipt: Bool = true) {
        guard !busy else { return }
        if removeReceipt, let request { DrawingRegistrationReceipt.remove(request) }
        request = nil; target = nil; received = nil; message = ""
    }
}

extension RelayPairingClient {
    func prepareDrawingRegistration(address: RelayAddress, privateKey: Data, relayKey: Data,
        request: DrawingRegistrationRequest, drawingIdentity: String, cancel: Bool = false) async throws {
        struct Command: Encodable {
            let version = 1, id = 1, op = "drawing-enrollment"
            let action: String, requestID: String, clientIdentity: String, drawingIdentity: String
        }
        struct Reply: Decodable {
            let version: Int, id: Int, ok: Bool
            let state: String?, requestID: String?, expiresIn: Int?, error: String?
        }
        let command = Command(action: cancel ? "cancel" : "prepare", requestID: request.requestID,
            clientIdentity: request.clientIdentity, drawingIdentity: drawingIdentity)
        let payload = try JSONEncoder().encode(command)
        let replies = try await managementRequests(address: address, privateKey: privateKey,
                                                  relayKey: relayKey, payloads: [payload])
        let reply = try JSONDecoder().decode(Reply.self, from: replies[0])
        guard reply.version == 1, reply.id == 1 else { throw RelaySetupError.protocolError }
        guard reply.ok else { throw RelaySetupError.rejected(reply.error ?? "Update the Relay package to register PLANK through Setup.") }
        guard reply.requestID == request.requestID, reply.state == (cancel ? "canceled" : "pending"),
              reply.expiresIn == (cancel ? 0 : 120) else { throw RelaySetupError.protocolError }
    }
}
