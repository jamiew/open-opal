import Foundation
import Security

@main
struct CameraSinkAuthorizationTests {
    static func main() {
        precondition(CommandLine.arguments.count == 3,
                     "Usage: sink-authorization-tests HOST_IDENTIFIER TEAM_IDENTIFIER")
        let hostID = CommandLine.arguments[1]
        let teamID = CommandLine.arguments[2]
        var selfCode: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        precondition(SecCodeCopySelf(SecCSFlags(), &selfCode) == errSecSuccess)
        precondition(SecCodeCopyStaticCode(selfCode!, SecCSFlags(), &staticCode) == errSecSuccess)
        precondition(SecCodeCopySigningInformation(staticCode!, SecCSFlags(), &information) == errSecSuccess)
        let identifier = (information as? [String: Any])?[kSecCodeInfoIdentifier as String] as? String
        precondition(identifier == hostID, "Sign this fixture ad hoc with the host identifier")
        let authorizer = SinkClientAuthorizer(hostIdentifier: hostID, teamIdentifier: teamID,
                                              hostInfoPlist: Data())!
        precondition(!authorizer.isAuthorized(pid: -1))
        precondition(!authorizer.isAuthorized(pid: getpid()))
        precondition(SinkClientAuthorizer(hostIdentifier: "", teamIdentifier: teamID,
                                         hostInfoPlist: Data()) == nil)
        precondition(SinkClientAuthorizer(hostIdentifier: hostID, teamIdentifier: "",
                                         hostInfoPlist: Data()) == nil)
        precondition(SinkClientAuthorizer() == nil)
        print("Sink authorization: an ad-hoc process with the real host identifier is rejected")
    }
}
