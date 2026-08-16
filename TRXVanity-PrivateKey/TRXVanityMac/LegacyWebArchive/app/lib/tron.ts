import { secp256k1 } from "@noble/curves/secp256k1.js";
import { sha256 } from "@noble/hashes/sha2.js";
import { keccak_256 } from "@noble/hashes/sha3.js";

const BASE58_ALPHABET =
  "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

export type TronKeypair = {
  address: string;
  privateKey: string;
};

function concatBytes(...parts: Uint8Array[]): Uint8Array {
  const size = parts.reduce((total, part) => total + part.length, 0);
  const output = new Uint8Array(size);
  let offset = 0;

  for (const part of parts) {
    output.set(part, offset);
    offset += part.length;
  }

  return output;
}

function bytesToHex(bytes: Uint8Array): string {
  let output = "";
  for (const byte of bytes) {
    output += byte.toString(16).padStart(2, "0");
  }
  return output.toUpperCase();
}

function hexToBytes(hex: string): Uint8Array {
  const normalized = hex.trim().replace(/^0x/i, "");
  if (!/^[0-9a-fA-F]{64}$/.test(normalized)) {
    throw new Error("私钥必须是 64 位十六进制字符。");
  }

  return Uint8Array.from(
    normalized.match(/.{2}/g)!.map((byte) => Number.parseInt(byte, 16)),
  );
}

function base58Encode(bytes: Uint8Array): string {
  let value = 0n;
  for (const byte of bytes) {
    value = (value << 8n) | BigInt(byte);
  }

  let output = "";
  while (value > 0n) {
    const remainder = Number(value % 58n);
    value /= 58n;
    output = BASE58_ALPHABET[remainder] + output;
  }

  for (const byte of bytes) {
    if (byte !== 0) break;
    output = "1" + output;
  }

  return output || "1";
}

function addressFromSecretKey(secretKey: Uint8Array): string {
  const publicKey = secp256k1.getPublicKey(secretKey, false);
  const publicKeyHash = keccak_256(publicKey.subarray(1));
  const payload = concatBytes(
    Uint8Array.of(0x41),
    publicKeyHash.subarray(publicKeyHash.length - 20),
  );
  const checksum = sha256(sha256(payload)).subarray(0, 4);
  return base58Encode(concatBytes(payload, checksum));
}

export function generateTronKeypair(): TronKeypair {
  const secretKey = secp256k1.utils.randomSecretKey();
  return {
    address: addressFromSecretKey(secretKey),
    privateKey: bytesToHex(secretKey),
  };
}

export function tronAddressFromPrivateKey(privateKey: string): string {
  return addressFromSecretKey(hexToBytes(privateKey));
}

