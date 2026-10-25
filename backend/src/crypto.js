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

// ------------------------------------------------- ClipLink Pro (v0.5+)

/** PBKDF2-SHA-256, deliberately parameterised for attacker cost, not speed. */
async function pbkdf2(password, saltBytes, iterations = 210_000) {
  const base = await crypto.subtle.importKey("raw", enc.encode(password), "PBKDF2", false, ["deriveBits"]);
  return new Uint8Array(await crypto.subtle.deriveBits(
    { name: "PBKDF2", hash: "SHA-256", salt: saltBytes, iterations }, base, 256
  ));
}

/** Password → { saltB64, hashB64 } for storage; plaintext is never kept. */
export async function hashPassword(password) {
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const hash = await pbkdf2(String(password), salt);
  return { saltB64: b64url(salt), hashB64: b64url(hash) };
}

/** Constant-time-ish verification against stored salt/hash (b64url strings). */
export async function verifyPassword(password, saltB64, hashB64) {
  if (!saltB64 || !hashB64) return false;
  const hash = await pbkdf2(String(password), unB64url(saltB64));
  const want = unB64url(hashB64);
  if (!want || hash.length !== want.length) return false;
  let diff = 0;
  for (let i = 0; i < hash.length; i++) diff |= hash[i] ^ want[i];
  return diff === 0;
}

async function grantKey(env) {
  const secret = String(env.TOKEN_SECRET || "");
  return crypto.subtle.importKey(
    "raw", enc.encode("grant:" + secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]
  );
}

/**
 * A short-lived forged-proof unlock grant for ONE share token. It authorises
 * downloading a password-protected share after the password was verified;
 * lives ~15 min, travels as an HttpOnly cookie or an X-ClipLink-Access header.
 */
export async function signAccessGrant(env, token, ttlMs = 15 * 60 * 1000) {
  const key = await grantKey(env);
  const exp = Date.now() + ttlMs;
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(`access:${token}:${exp}`)));
  return { exp, grant: `${exp}.${b64url(mac)}` };
}

export async function verifyAccessGrant(env, token, grant) {
  if (!grant || !grant.includes(".")) return false;
  const dot = grant.indexOf(".");
  const exp = Number(grant.slice(0, dot));
  const sig = grant.slice(dot + 1);
  if (!Number.isFinite(exp) || Date.now() > exp) return false;
  const key = await grantKey(env);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(`access:${token}:${exp}`)));
  return b64url(mac) === sig; // base64url of equal bytes is byte-equal
}
