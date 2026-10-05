import CoreMedia
import Foundation
import Security

/// Convert host-clock timing without trapping on producer-supplied values.
enum SinkTiming {
    static func hostTimeInNanoseconds(_ time: CMTime) -> UInt64? {
        guard time.isNumeric, time.value >= 0 else { return nil }
        let nanoseconds = CMTimeConvertScale(time, timescale: 1_000_000_000,
                                            method: .roundTowardZero)
        guard nanoseconds.isNumeric, nanoseconds.value >= 0 else { return nil }
        return UInt64(nanoseconds.value)
    }
}

/// Accessed only on the provider's serial client queue.
struct SinkSession {
    private(set) var clientID: UUID?
    private var generation: UInt64 = 0
    private var isStreaming = false

    mutating func authorize(_ id: UUID) -> Bool {
        guard clientID == nil || clientID == id else { return false }
        clientID = id
        return true
    }

    mutating func start() -> UInt64? {
        guard clientID != nil, !isStreaming else { return nil }
        generation &+= 1
        isStreaming = true
        return generation
    }

    mutating func stop() {
        generation &+= 1
        isStreaming = false
        clientID = nil
    }

    func accepts(_ id: UUID, generation: UInt64) -> Bool {
        isStreaming && clientID == id && self.generation == generation
    }
}

/// Trust the host identifier and Apple developer team sealed into this extension.
struct SinkClientAuthorizer {
    private let hostIdentifier: String
    private let requirement: SecRequirement

    init?() {
        let flags = SecCSFlags()
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf(flags, &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, flags, nil) == errSecSuccess,
              SecCodeCopyStaticCode(code, flags, &staticCode) == errSecSuccess,
              let staticCode,
              SecCodeCopySigningInformation(staticCode,
                  SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let identifier = values[kSecCodeInfoIdentifier as String] as? String,
              identifier.hasSuffix(".camera"),
              let team = values[kSecCodeInfoTeamIdentifier as String] as? String else { return nil }
        self.init(hostIdentifier: String(identifier.dropLast(".camera".count)),
                  teamIdentifier: team)
    }

    init?(hostIdentifier: String, teamIdentifier: String) {
        guard !hostIdentifier.isEmpty, !teamIdentifier.isEmpty else { return nil }
        func quoted(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let expression = "anchor apple generic and identifier \(quoted(hostIdentifier)) "
            + "and certificate leaf[subject.OU] = \(quoted(teamIdentifier))"
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(expression as CFString, SecCSFlags(),
                                             &requirement) == errSecSuccess,
              let requirement else { return nil }
        self.hostIdentifier = hostIdentifier
        self.requirement = requirement
    }

    func isAuthorized(signingID: String?, pid: pid_t) -> Bool {
        guard signingID == hostIdentifier, pid > 0 else { return false }
        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &code)
                == errSecSuccess, let code else { return false }
        return SecCodeCheckValidity(code, SecCSFlags(), requirement) == errSecSuccess
    }
}
