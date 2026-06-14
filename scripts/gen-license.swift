#!/usr/bin/env swift
// Issue a signed Gatecaster Pro license key for a customer.
//
//   GATECASTER_PRIVATE_KEY=<base64-private-key> \
//       swift scripts/gen-license.swift "Customer Name" pro
//
// Prints one license key string. Hand it to the customer; they paste it into
// Gatecaster → "Unlock Pro…". The key is a signed token (no server check), so
// verification works fully offline. `tier` defaults to "pro"; the only tiers the
// app honors today are "free" (the default, no key needed) and "pro".
//
// The private key is the secret half of the pair from gen-keypair.swift. Keep it
// OFFLINE; anyone holding it can mint licenses.

import CryptoKit
import Foundation

let args = CommandLine.arguments
let name = args.count > 1 ? args[1] : "Unnamed"
let tier = args.count > 2 ? args[2] : "pro"

guard let pkB64 = ProcessInfo.processInfo.environment["GATECASTER_PRIVATE_KEY"],
      let pkData = Data(base64Encoded: pkB64),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: pkData) else {
    FileHandle.standardError.write(Data(
        "error: set GATECASTER_PRIVATE_KEY to your base64 private key (from gen-keypair.swift)\n".utf8))
    exit(1)
}

// Sign the EXACT payload bytes we ship in the key; the app verifies the signature
// over those same bytes before trusting `tier`. `iat` (issued-at) is informational.
let payload: [String: Any] = ["name": name, "tier": tier, "iat": Int(Date().timeIntervalSince1970)]
let payloadData = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
let sig = try! key.signature(for: payloadData)

func b64url(_ d: Data) -> String {
    d.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

print("\(b64url(payloadData)).\(b64url(sig))")
