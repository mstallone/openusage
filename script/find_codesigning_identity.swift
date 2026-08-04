import Foundation
import LocalAuthentication
import Security

private func fail(_ message: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(status)
}

private func organizationalUnit(of certificate: SecCertificate) -> String? {
    guard
        let values = SecCertificateCopyValues(
            certificate,
            [kSecOIDX509V1SubjectName] as CFArray,
            nil
        ) as? [String: Any],
        let subject = values[kSecOIDX509V1SubjectName as String] as? [String: Any],
        let fields = subject[kSecPropertyKeyValue as String] as? [[String: Any]]
    else {
        return nil
    }

    return fields.first { field in
        field[kSecPropertyKeyLabel as String] as? String == kSecOIDOrganizationalUnitName as String
    }?[kSecPropertyKeyValue as String] as? String
}

private func isValidForCodeSigning(_ certificate: SecCertificate) -> Bool {
    guard let policy = SecPolicyCreateWithProperties(kSecPolicyAppleCodeSigning, nil) else {
        return false
    }
    var trust: SecTrust?
    guard
        SecTrustCreateWithCertificates(certificate, policy, &trust) == errSecSuccess,
        let trust
    else {
        return false
    }
    SecTrustSetNetworkFetchAllowed(trust, false)
    return SecTrustEvaluateWithError(trust, nil)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2 else {
    fail("usage: find_codesigning_identity.swift <certificate-name-prefix> <team-id>")
}
let namePrefix = arguments[0]
let teamID = arguments[1]

// Identity discovery is non-interactive. A prompt here would authorize this short-lived Swift
// helper rather than codesign or Runway, and a locked Keychain should fail the build explicitly.
let authenticationContext = LAContext()
authenticationContext.interactionNotAllowed = true
let query: [String: Any] = [
    kSecClass as String: kSecClassIdentity,
    kSecMatchLimit as String: kSecMatchLimitAll,
    kSecReturnRef as String: true,
    kSecUseAuthenticationContext as String: authenticationContext,
]
var result: CFTypeRef?
let queryStatus = SecItemCopyMatching(query as CFDictionary, &result)
if queryStatus == errSecItemNotFound {
    exit(1)
}
guard queryStatus == errSecSuccess else {
    fail("could not read code-signing identities (OSStatus \(queryStatus))", status: 2)
}
guard let identities = result as? [SecIdentity] else {
    fail("the Keychain returned an unexpected identity result", status: 2)
}

for identity in identities {
    var certificate: SecCertificate?
    guard
        SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
        let certificate,
        let name = SecCertificateCopySubjectSummary(certificate) as String?,
        name.hasPrefix(namePrefix),
        organizationalUnit(of: certificate) == teamID,
        isValidForCodeSigning(certificate)
    else {
        continue
    }

    print(name)
    exit(0)
}

exit(1)
