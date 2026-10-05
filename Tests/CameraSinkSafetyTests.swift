import CoreMedia
import Foundation
import Security

/// Compile alongside SinkSafety.swift. No camera or extension registration is involved.
@main
struct CameraSinkSafetyTests {
    static func main() {
        precondition(SinkTiming.hostTimeInNanoseconds(.zero) == 0)
        precondition(SinkTiming.hostTimeInNanoseconds(CMTime(value: 1, timescale: 30)) == 33_333_333)
        precondition(SinkTiming.hostTimeInNanoseconds(CMTime(value: 1, timescale: 3)) == 333_333_333)
        precondition(SinkTiming.hostTimeInNanoseconds(
            CMTime(value: Int64.max, timescale: 1_000_000_000)) == UInt64(Int64.max))
        for time in [CMTime.invalid, .indefinite, .positiveInfinity, .negativeInfinity,
                     CMTime(value: -1, timescale: 30), CMTime(value: Int64.max, timescale: 1)] {
            precondition(SinkTiming.hostTimeInNanoseconds(time) == nil)
        }

        let first = UUID()
        let second = UUID()
        var session = SinkSession()
        precondition(session.start() == nil)
        precondition(session.authorize(first))
        precondition(session.authorize(first))
        precondition(!session.authorize(second))
        let firstGeneration = session.start()!
        precondition(session.start() == nil)
        precondition(session.accepts(first, generation: firstGeneration))
        precondition(!session.accepts(second, generation: firstGeneration))
        session.stop()
        precondition(!session.accepts(first, generation: firstGeneration))
        precondition(session.authorize(second))
        let secondGeneration = session.start()!
        precondition(!session.accepts(first, generation: firstGeneration))
        precondition(session.accepts(second, generation: secondGeneration))
        session.stop()
        precondition(session.authorize(second))
        let restartedGeneration = session.start()!
        precondition(!session.accepts(second, generation: secondGeneration))
        precondition(session.accepts(second, generation: restartedGeneration))

        let hostID = "com.jamiedubs.open-opal"
        var selfCode: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        precondition(SecCodeCopySelf(SecCSFlags(), &selfCode) == errSecSuccess)
        precondition(SecCodeCopyStaticCode(selfCode!, SecCSFlags(), &staticCode) == errSecSuccess)
        precondition(SecCodeCopySigningInformation(staticCode!, SecCSFlags(), &information) == errSecSuccess)
        let identifier = (information as? [String: Any])?[kSecCodeInfoIdentifier as String] as? String
        precondition(identifier == hostID, "Sign this fixture ad hoc with the host identifier")
        let authorizer = SinkClientAuthorizer(hostIdentifier: hostID, teamIdentifier: "GFU82T28YT")!
        precondition(!authorizer.isAuthorized(signingID: nil, pid: getpid()))
        precondition(!authorizer.isAuthorized(signingID: "another.app", pid: getpid()))
        precondition(!authorizer.isAuthorized(signingID: hostID, pid: -1))
        precondition(!authorizer.isAuthorized(signingID: hostID, pid: getpid()))
        precondition(SinkClientAuthorizer(hostIdentifier: "", teamIdentifier: "GFU82T28YT") == nil)
        precondition(SinkClientAuthorizer(hostIdentifier: hostID, teamIdentifier: "") == nil)
        print("Camera sink safety: passed invalid timing, exclusive ownership, stale sessions, and untrusted producer checks")
    }
}
