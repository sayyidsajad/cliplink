/**
 * AES-GCM helpers for encrypting provider tokens at rest in D1.
 *
 * Your OAuth connection tokens (Google refresh tokens, account labels) never
 * ride around in plaintext in the metadata DB: they're sealed with a key
 * derived (SHA-256) from the TOKEN_SECRET Worker secret. Losing TOKEN_SECRET
 * invalidates the stored tokens, nothing else — reconnecting fixes it.
 *
 * Format:  "enc1:" <b64url(iv)> "." <b64url(ciphertext)>
 */

const enc = new TextEncoder();
const dec = new TextDecoder();

function b64url(bytes) {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function unB64url(s) {
  const pad = s.length % 4 === 0 ? "" : "=".repeat(4 - (s.length % 4));
  const bin = atob(s.replace(/-/g, "+").replace(/_/g, "/") + pad);
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

async function deriveKey(env) {
  const secret = String(env.TOKEN_SECRET || "");
  if (!secret) {
    const e = new Error("token_secret_missing: TOKEN_SECRET worker secret is not set");
    e.status = 500;
    throw e;
  }
  const digest = await crypto.subtle.digest("SHA-256", enc.encode(secret));
  return crypto.subtle.importKey("raw", digest, "AES-GCM", false, ["encrypt", "decrypt"]);
}

/** Encrypts a UTF-8 string; returns an opaque "enc1:…" token safe to store in SQL. */
export async function sealText(env, plaintext) {
  const key = await deriveKey(env);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const cipher = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv },
    key,
    enc.encode(String(plaintext || ""))
  );
  return `enc1:${b64url(iv)}.${b64url(new Uint8Array(cipher))}`;
}

/** Reverses sealText. Returns the plaintext string or null for malformed input. */
export async function openText(env, stored) {
  const value = String(stored || "");
  if (!value.startsWith("enc1:")) return null;
  const [ivPart, ctPart] = value.slice(5).split(".");
  if (!ivPart || !ctPart) return null;
  try {
    const key = await deriveKey(env);
    const plain = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: unB64url(ivPart) },
      key,
      unB64url(ctPart)
    );
    return dec.decode(plain);
  } catch {
    return null;
  }
}
