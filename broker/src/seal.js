// libsodium's crypto_box_seal, which GitHub uses for repository secrets,
// built from pure-JS audited libraries: tweetnacl (X25519 + XSalsa20-Poly1305
// crypto_box) and @noble/hashes (BLAKE2b). libsodium-wrappers itself loads
// WebAssembly from bytes at run time, which Cloudflare Workers don't allow.
//
// Sealed box = ephemeral public key (32 bytes) ‖ crypto_box(message,
//   nonce = BLAKE2b-192(ephemeral pk ‖ recipient pk), recipient pk, ephemeral sk).
// tests/broker/secrets.test.mjs opens the output with libsodium's
// crypto_box_seal_open to prove compatibility.

import nacl from "tweetnacl";
import { blake2b } from "@noble/hashes/blake2.js";

function fromB64(s) {
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function toB64(bytes) {
  let bin = "";
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(bin);
}

// seal(messageUtf8, recipientPublicKeyB64) -> base64 sealed box, or throws
// when the public key isn't 32 bytes.
export function seal(message, recipientPkB64) {
  const pk = fromB64(recipientPkB64);
  if (pk.length !== nacl.box.publicKeyLength) throw new Error("bad public key");
  const eph = nacl.box.keyPair();
  const nonceInput = new Uint8Array(64);
  nonceInput.set(eph.publicKey, 0);
  nonceInput.set(pk, 32);
  const nonce = blake2b(nonceInput, { dkLen: nacl.box.nonceLength });
  const box = nacl.box(new TextEncoder().encode(message), nonce, pk, eph.secretKey);
  eph.secretKey.fill(0);
  const out = new Uint8Array(32 + box.length);
  out.set(eph.publicKey, 0);
  out.set(box, 32);
  return toB64(out);
}
