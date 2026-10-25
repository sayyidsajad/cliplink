/**
 * ClipLink Pro — one-time license verification.
 *
 * Self-issued keys (no external licensing server): a key is
 *   15 bytes of "CLPRO-XXXX-XXXX-XXXX-XXXX" where the underlying payload is
 *   bytes[0..7] = first 8 bytes of HMAC-SHA256(LICENSE_KEY_SEED, serial)
 *   bytes[8..9] = first 2 bytes of HMAC-SHA256(LICENSE_KEY_SEED, bytes[0..7])
 * rendered as base32 (16 chars). Possessing the payload implies having been
 * minted with the seed; nobody can forge a key without the server-side
 * secret, and nothing needs to be stored to verify a key.
 *
 * Verified presentations are cached/bound in D1 (`licenses`): the app sends
 * X-ClipLink-License on uploads while Pro features are in use; we keep only
 * a salted key id (never the raw key) plus a small install-id list. One key
 * supports a handful of installs; resettable manually.
 */

const enc = new TextEncoder();

const B32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
const PREFIX = "CLPRO-";
const MAX_INSTALLS_PER_KEY = 5;
const RECHECK_MS = 30 * 24 * 3600 * 1000; // lazy freshness touch on the cache

function toB32(bytes) {
  let bits = "";
  for (const b of bytes) bits += b.toString(2).padStart(8, "0");
  bits = bits.padEnd(Math.ceil(bits.length / 5) * 5, "0");
  let out = "";
  for (let i = 0; i < bits.length; i += 5) out += B32[parseInt(bits.slice(i, i + 5), 2) | 0];
  return out;
}

function fromB32(s) {
  let bits = "";
  for (const c of s) {
    const idx = B32.indexOf(c);
    if (idx < 0) return null;
    bits += idx.toString(2).padStart(5, "0");
  }
  const out = new Uint8Array(Math.floor(bits.length / 8));
  for (let i = 0; i < out.length; i++) out[i] = parseInt(bits.slice(i * 8, i * 8 + 8), 2);
  return out;
}

async function hmacSign(env, data) {
  const seed = String(env.LICENSE_KEY_SEED || "");
  if (!seed) return null;
  const key = await crypto.subtle.importKey(
    "raw", enc.encode(seed), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]
  );
  return new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(data)));
}

/** Arbitrary-normalise user input → the 16-char compact payload, or null. */
export function normalizeLicenseKey(raw) {
  let s = String(raw || "").trim().toUpperCase().replace(/[\u200B-\u200D\uFEFF]/g, "").replace(/[^A-Z0-9]/g, "");
  if (!s.startsWith("CLPRO")) return null;
  s = s.replace(/^CLPRO/, "");
  return (s.length === 16 && /^[A-Z2-7]+$/.test(s)) ? s : null;
}

/** Mint a key for a serial/counter (e.g. "0001", customer e-mail, date+no). */
export async function generateLicenseKey(env, serial) {
  const payload = await hmacSign(env, String(serial));
  if (!payload) throw new Error("license_seed_missing: LICENSE_KEY_SEED not configured");
  const compact = payload.slice(0, 8);
  const tag = (await hmacSign(env, "tag:" + toB32(compact))).slice(0, 2);
  const full = new Uint8Array(10);
  full.set(compact, 0); full.set(tag, 8);
  const b32 = toB32(full);
  return PREFIX + [b32.slice(0, 4), b32.slice(4, 8), b32.slice(8, 12), b32.slice(12, 16)].join("-");
}

/** True iff the presented 16-char payload was minted with our seed. */
export async function verifyLicenseKeyCompact(env, compact) {
  const bytes = fromB32(compact);
  if (!bytes || bytes.length !== 10) return false;
  const tag = (await hmacSign(env, "tag:" + toB32(bytes.slice(0, 8))));
  if (!tag) return false;
  return bytes[8] === tag[0] && bytes[9] === tag[1];
}

/** Stable, non-reversible row id for the presented key (never store raw). */
export async function licenseKeyId(env, compact) {
  const digest = await crypto.subtle.digest("SHA-256", enc.encode("keyid:" + compact + ":" + String(env.LICENSE_KEY_SEED || "")));
  return toB32(new Uint8Array(digest)).slice(0, 26);
}

export function licenseConfig(env) {
  return { proSalesEnabled: Boolean(String(env.LICENSE_KEY_SEED || "").trim()), maxInstallsPerKey: MAX_INSTALLS_PER_KEY };
}

/**
 * Validates the license presented with a request and maintains the D1 binding
 * row. Returns { active: false, reason } for any doubt — never throws.
 */
export async function checkLicense(env, install, presentedRaw) {
  const compact = normalizeLicenseKey(presentedRaw);
  if (!compact) return { active: false, reason: "malformed" };
  if (!(await verifyLicenseKeyCompact(env, compact))) return { active: false, reason: "invalid" };
  const keyId = await licenseKeyId(env, compact);
  const now = Date.now();
  const row = await env.DB.prepare("SELECT rowid AS rid, * FROM licenses WHERE key_id = ?1").bind(keyId).first();
  if (!row) {
    await env.DB.prepare(
      "INSERT INTO licenses (key_id, installs, first_seen_at, last_check_at) VALUES (?1, ?2, ?3, ?3)"
    ).bind(keyId, JSON.stringify(install ? [install] : []), now).run();
    return { active: true, keyId };
  }
  if (!row.last_check_at || now - row.last_check_at > RECHECK_MS) {
    await env.DB.prepare("UPDATE licenses SET last_check_at = ?2 WHERE key_id = ?1").bind(keyId, now).run();
  }
  let installs = [];
  try { installs = JSON.parse(row.installs || "[]"); } catch { installs = []; }
  if (install && !installs.includes(install)) {
    if (installs.length >= MAX_INSTALLS_PER_KEY) {
      return { active: false, reason: "install_limit", installs: installs.length };
    }
    installs.push(install);
    await env.DB.prepare("UPDATE licenses SET installs = ?2 WHERE key_id = ?1").bind(keyId, JSON.stringify(installs)).run();
  }
  return { active: true, keyId };
}
