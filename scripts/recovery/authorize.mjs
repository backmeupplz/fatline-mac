import { HDKey } from "@scure/bip32";
import { secp256k1 } from "@noble/curves/secp256k1";
import { encodeAbiParameters, hashTypedData, keccak256 } from "viem";
import { mnemonicToSeedSync, validateMnemonic } from "@scure/bip39";
import { wordlist } from "@scure/bip39/wordlists/english.js";

const domain = { name: "Farcaster KeyAdd", version: "1", chainId: 1 };
const signedKeyRequest = [
  { name: "requestFid", type: "uint256" },
  { name: "key", type: "bytes" },
  { name: "deadline", type: "uint256" }
];
const keyAdd = [
  { name: "fid", type: "uint256" },
  { name: "key", type: "bytes" },
  { name: "keyType", type: "uint32" },
  { name: "scopes", type: "uint32[]" },
  { name: "ttl", type: "uint32" },
  { name: "nonce", type: "uint32" },
  { name: "deadline", type: "uint256" }
];

globalThis.recoverFarcasterAccount = (phrase) => {
  const mnemonic = phrase.trim().toLowerCase().split(/\s+/u).join(" ");
  if (![12, 24].includes(mnemonic.split(" ").length) || !validateMnemonic(mnemonic, wordlist)) return null;
  const key = HDKey.fromMasterSeed(mnemonicToSeedSync(mnemonic)).derive("m/44'/60'/0'/0/0").privateKey;
  const address = "0x" + keccak256(secp256k1.getPublicKey(key, false).slice(1)).slice(-40);
  const sign = (typedData) => {
    const signature = secp256k1.sign(hashTypedData(typedData).slice(2), key, { lowS: true });
    return "0x" + signature.toCompactHex() + (signature.recovery ? "1c" : "1b");
  };
  return {
    address: address,
    authorize(fid, key, deadline, nonce, ttl) {
      const requestFid = BigInt(fid);
      const deadlineValue = BigInt(deadline);
      const signature = sign({
        domain, types: { SignedKeyRequest: signedKeyRequest }, primaryType: "SignedKeyRequest",
        message: { requestFid, key, deadline: deadlineValue }
      });
      const metadata = encodeAbiParameters(
        [{ type: "tuple", components: [
          { name: "requestFid", type: "uint256" }, { name: "requestSigner", type: "address" },
          { name: "signature", type: "bytes" }, { name: "deadline", type: "uint256" }
        ] }],
        [{ requestFid, requestSigner: address, signature, deadline: deadlineValue }]
      );
      const custodySignature = sign({
        domain, types: { KeyAdd: keyAdd }, primaryType: "KeyAdd",
        message: { fid: requestFid, key, keyType: 1, scopes: [1, 2], ttl, nonce, deadline: deadlineValue }
      });
      return { metadata, custodySignature };
    }
  };
};
