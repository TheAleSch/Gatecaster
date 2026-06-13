#!/usr/bin/env swift
// Generate an Ed25519 key pair for signing Gatecaster Pro licenses.
//
//   swift scripts/gen-keypair.swift
//
// Run this ONCE. Paste the PUBLIC key into License.swift (`publicKeyB64`) and
// keep the PRIVATE key OFFLINE and secret (a password manager — never the repo).
// The private key signs licenses (gen-license.swift); the public key, baked into
// the app, verifies them. Rotating the key invalidates every license already
// issued, so treat the private key as the one irreplaceable secret.

import CryptoKit
import Foundation

let key = Curve25519.Signing.PrivateKey()
print("PRIVATE (keep secret, offline): \(key.rawRepresentation.base64EncodedString())")
print("PUBLIC  (paste into License.swift): \(key.publicKey.rawRepresentation.base64EncodedString())")
