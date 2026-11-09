import CryptoKit
import Foundation
import XCTest
@testable import BrowserApp

final class BrowserAgentPhoneConnectionTests: XCTestCase {
    func testPhoneLinksCarryIdentityAndPublicKeyOnly() throws {
        let phoneKey = P256.KeyAgreement.PrivateKey()
        for host in ["192.168.1.7", "198.51.100.8", "2001:db8::8", "phone.example.com"] {
            let phone = BrowserAgentPhone(id: UUID().uuidString.lowercased(), name: "My Phone", host: host,
                                           port: 38_766, publicKey: phoneKey.publicKey.derRepresentation)
            let link = try XCTUnwrap(phone.link)
            XCTAssertEqual(try BrowserAgentPhone.parse(link), phone)
            XCTAssertFalse(link.absoluteString.contains("key="))
            XCTAssertThrowsError(try BrowserAgentPhone.parse(XCTUnwrap(URL(string: link.absoluteString + "&pub=bad"))))
            XCTAssertThrowsError(try BrowserAgentPhone.parse(XCTUnwrap(URL(string: link.absoluteString + "#fragment"))))
        }
        let invalid = BrowserAgentPhone(id: UUID().uuidString.lowercased(), name: "Phone", host: "192.168.1.7",
                                         port: 38_766, publicKey: Data(repeating: 0, count: 91))
        XCTAssertThrowsError(try BrowserAgentPhone.parse(XCTUnwrap(invalid.link)))
    }

    func testECDHOfferContainsNoModelCredentialAndMatchesVerificationVector() throws {
        let sender = try scalar(1)
        let phoneKey = try scalar(2)
        let phone = BrowserAgentPhone(id: UUID().uuidString.lowercased(), name: "Phone", host: "127.0.0.1",
                                       port: 38_766, publicKey: phoneKey.publicKey.derRepresentation)
        let connection = try BrowserAgentPhoneConnection(phone: phone, senderKey: sender)
        XCTAssertEqual(connection.keyData.map { String(format: "%02x", $0) }.joined(),
                       "e1874eff53a65e2883977044a23e89c8b8ba49f737b35f52e9c975861dd1652d")
        XCTAssertEqual(connection.verificationCode, "021671")
        let identity = UUID().uuidString
        let sealed = try connection.seal(["id": identity, "name": "Study Mac", "createdAt": 1_794_067_308])
        let envelope = try JSONDecoder().decode(BrowserAgentPhoneConnection.Envelope.self, from: sealed.body)
        XCTAssertEqual(Data(base64Encoded: envelope.publicKey), sender.publicKey.derRepresentation)
        let shared = try phoneKey.sharedSecretFromKeyAgreement(with: sender.publicKey).withUnsafeBytes { Data($0) }
        let derived = Data(SHA256.hash(data: Data("BrowserAgent/phone-invite/v1".utf8) + shared +
                                      sender.publicKey.derRepresentation + phoneKey.publicKey.derRepresentation))
        let box = try AES.GCM.SealedBox(combined: XCTUnwrap(Data(base64Encoded: envelope.data)))
        let plaintext = try AES.GCM.open(box, using: SymmetricKey(data: derived),
                                         authenticating: Data("BrowserAgent/phone-invite/v1 request".utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: plaintext) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["id", "name", "createdAt"]))
        XCTAssertEqual(object["id"] as? String, identity)
        XCTAssertNil(object["pairingLink"])
    }

    func testResponseAuthenticatesPhoneIdentityAndOriginalRequest() throws {
        let sender = try scalar(1)
        let phoneKey = try scalar(2)
        let phone = BrowserAgentPhone(id: UUID().uuidString.lowercased(), name: "Phone", host: "127.0.0.1",
                                       port: 38_766, publicKey: phoneKey.publicKey.derRepresentation)
        let connection = try BrowserAgentPhoneConnection(phone: phone, senderKey: sender)
        let request = try connection.seal(["name": "Mac", "id": UUID().uuidString, "createdAt": 1])
        let plaintext = Data(#"{"accepted":true,"remembered":false}"#.utf8)
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: connection.keyData),
                                      authenticating: BrowserAgentPhoneConnection.responseAAD + request.nonce)
        let response = try JSONEncoder().encode(BrowserAgentPhoneConnection.Envelope(
            publicKey: phone.publicKey.base64EncodedString(), data: XCTUnwrap(sealed.combined).base64EncodedString()))
        let result = try connection.open(response, requestNonce: request.nonce)
        XCTAssertTrue(result.accepted)
        XCTAssertEqual(result.remembered, false)
        let otherRequest = try connection.seal(["name": "Mac", "id": UUID().uuidString, "createdAt": 2])
        XCTAssertThrowsError(try connection.open(response, requestNonce: otherRequest.nonce))
        let replacedKey = try JSONEncoder().encode(BrowserAgentPhoneConnection.Envelope(
            publicKey: sender.publicKey.derRepresentation.base64EncodedString(),
            data: XCTUnwrap(sealed.combined).base64EncodedString()))
        XCTAssertThrowsError(try connection.open(replacedKey, requestNonce: request.nonce))
        XCTAssertThrowsError(try connection.open(Data(repeating: 0, count: 16_385), requestNonce: request.nonce))
    }

    private func scalar(_ value: UInt8) throws -> P256.KeyAgreement.PrivateKey {
        var bytes = Data(repeating: 0, count: 32)
        bytes[31] = value
        return try P256.KeyAgreement.PrivateKey(rawRepresentation: bytes)
    }
}
