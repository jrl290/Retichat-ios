// IdentityShareFormatTests.swift
//
// Focused regression tests for Columba-style contact URIs.
// Run with:
//
//   swiftc -o /tmp/identity-share-tests \
//     Retichat-ios/Retichat/Services/IdentityShareFormat.swift \
//     Retichat-ios/tests/IdentityShareFormatTests.swift && \
//     /tmp/identity-share-tests

import Foundation

extension Data {
    init?(hexString: String) {
        let hex = hexString.replacingOccurrences(of: " ", with: "")
        guard hex.count % 2 == 0 else { return nil }

        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

var failures: [String] = []

func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() {
        print("ok    - \(name)")
    } else {
        print("FAIL  - \(name)")
        failures.append(name)
    }
}

let hash = "0123456789abcdef0123456789abcdef"
let publicKey = Data((0..<64).map { UInt8($0) })

@main
enum IdentityShareFormatTests {
    static func main() {
        if let encoded = IdentityShareFormat.encode(destinationHashHex: hash, publicKey: publicKey) {
            check(encoded == "lxma://\(hash):\(publicKey.hexString)", "encode Columba URI")
            let decoded = IdentityShareFormat.parse(encoded)
            check(decoded?.destinationHashHex == hash, "decode hash from Columba URI")
            check(decoded?.publicKey == publicKey, "decode public key from Columba URI")
        } else {
            check(false, "encode Columba URI")
        }

        let legacy = IdentityShareFormat.parse("lxmf://\(hash)")
        check(legacy?.destinationHashHex == hash, "decode legacy hash URI")
        check(legacy?.publicKey == nil, "legacy hash URI has no public key")

        let raw = IdentityShareFormat.parse("\(hash):\(publicKey.hexString)")
        check(raw?.destinationHashHex == hash, "decode raw hash:pubkey form")
        check(raw?.publicKey == publicKey, "decode raw public key form")

        check(IdentityShareFormat.parse("lxm://ignored-paper-format") == nil, "ignore PAPER format")

        if failures.isEmpty {
            print("all tests passed")
            exit(0)
        } else {
            print("\n\(failures.count) failure(s)")
            exit(1)
        }
    }
}