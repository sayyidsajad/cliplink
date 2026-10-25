/**
 * ClipLink backend — Cloudflare Worker.
 *
 * Endpoints:
 *   POST   /api/v1/shares                 upload (raw body) -> create public share
 *   GET    /api/v1/limits                 advertised limits (JSON)
 *   GET    /api/v1/shares/:token          share metadata (JSON)
 *   GET    /api/v1/shares/:token/download file download (streams from the owner's Drive)
 *   DELETE /api/v1/shares/:token          revoke (requires per-share revoke token or admin token)
 *   GET    /s/:token                      human download page
 *   GET    /api/v1/providers/drive/authorize  start BYO Google-Drive connect {url, state}
 *   GET    /api/v1/providers/drive/poll?state=  app polls -> {connected, email}
 *   GET    /oauth/drive/callback          Google OAuth redirect target (HTML, closes)
 *   GET    /healthz
 * plus a scheduled job that deletes expired objects (hosting files in the
 * user's own cloud storage; the operator's infra stores zero bytes).
 *
 * Design notes (PRD §7):
 *  - Public share tokens buy access to ONE object only; tokens are random
 *    strings from a no-lookalike 56-char alphabet generated with
 *    crypto.getRandomValues (rejection sampling to stay unbiased).
 *  - Only the uploader's secret per-share revoke token or the server-side
 *    ADMIN_TOKEN secret can delete a share. A public token alone never revokes.
 *  - Size/rate limits come from wrangler [vars] and are enforced server-side
 *    on every request; the client's install id is ONLY a rate-limiting key.
 *  - Expiration is enforced on every request, even if cleanup has not run yet.
 *  - BYO storage (v0.4+): files live in the user's own Google Drive; the
 *    Worker stores metadata and OAuth refresh tokens sealed with AES-GCM.
 *    Legacy Supabase shares keep working until every row expires, then the
 *    Supabase project is retired.
 */

import { sharePage, errorPage, humanBytes } from "./page.js";
import { makeStorage, storageKeepAlive } from "./supabase.js";
import {
  makeDriveStorage, buildAuthorizeUrl, exchangeCode, sealConnection,
  revealAccountEmail, newId, StorageError, fetchAccountEmail,
} from "./drive.js";
import { makeMockStorage } from "./mock.js";

const TOKEN_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789";
const TOKEN_REGEX = /^[A-Za-z0-9_-]{8,64}$/;
const INSTALL_REGEX = /^[0-9a-fA-F-]{32,40}$/;
const TOKEN_LENGTH = 11;
const REVOKE_TOKEN_LENGTH = 30;
const PLAIN_HTTP_HOSTS = new Set(["127.0.0.1", "localhost", "::1"]);

class ApiError extends Error {
  constructor(status, code, message, headers) {
    super(message);
    this.status = status;
    this.code = code;
    this.headers = headers;
  }
}

const SECURITY_HEADERS = {
  "x-content-type-options": "nosniff",
  "x-frame-options": "DENY",
  "referrer-policy": "no-referrer",
  "content-security-policy":
    "default-src 'none'; style-src 'unsafe-inline'; img-src 'none'; script-src 'none'; form-action 'none'; base-uri 'none'; frame-ancestors 'none'",
};

const json = (data, status = 200, headers = {}) =>
  new Response(JSON.stringify(data, null, 2), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", ...SECURITY_HEADERS, ...headers },
  });

const html = (body, status = 200) =>
  new Response(body, {
    status,
    headers: { "content-type": "text/html; charset=utf-8", ...SECURITY_HEADERS },
  });

// ---------------------------------------------------------------- config

function readConfig(env) {
  const num = (v, fallback) => {
    const n = Number.parseFloat(v);
    return Number.isFinite(n) && n > 0 ? n : fallback;
  };
  const hours = num(env.EXPIRY_HOURS, 24);
  const minutes = (env.EXPIRY_MINUTES !== undefined && env.EXPIRY_MINUTES !== "")
    ? num(env.EXPIRY_MINUTES, hours * 60)
    : hours * 60;
  // Storage budget against the R2 free tier. 0 disables the guard.
  const maxStorageGB = env.MAX_STORAGE_GB !== undefined && env.MAX_STORAGE_GB !== ""
    ? Math.max(0, Number.parseFloat(env.MAX_STORAGE_GB) || 0)
    : 9;
  return {
    maxFileBytes: Math.round(num(env.MAX_FILE_MB, 100) * 1024 * 1024),
    maxStorageBytes: Math.round(maxStorageGB * 1024 * 1024 * 1024),
    expiryMs: Math.round(minutes * 60 * 1000),
    rateLimitUploads: Math.round(num(env.RATE_LIMIT_UPLOADS, 30)),
    rateWindowMs: Math.round(num(env.RATE_WINDOW_MINUTES, 60) * 60 * 1000),
    retentionMs: Math.round(num(env.ROW_RETENTION_DAYS, 7) * 24 * 60 * 60 * 1000),
    publicBaseUrl: String(env.PUBLIC_BASE_URL || "").trim().replace(/\/+$/, ""),
    adminToken: env.ADMIN_TOKEN || null,
    tokenLength: TOKEN_LENGTH,
    // BYO storage (v0.4+): "drive" = files live in the user's own Google Drive.
    // "mock" = local/CI test provider (must be explicitly enabled).
    // "supabase" = legacy hosted storage; kept only until legacy rows expire.
    storageProvider: (() => {
      const explicit = String(env.STORAGE_PROVIDER || "").trim().toLowerCase();
      if (explicit) return explicit;
      if (env.MOCK_PROVIDER === "1") return "mock";
      if (env.DRIVE_CLIENT_ID) return "drive";
      return "supabase"; // transition default until OAuth client is created
    })(),
    driveConfigured: Boolean(env.DRIVE_CLIENT_ID && env.DRIVE_CLIENT_SECRET),
    allowGuestShares: env.MOCK_PROVIDER === "1", // dev/CI sandbox only
  };
}

// ---------------------------------------------------------------- helpers

function randomToken(len) {
  const alphabet = TOKEN_ALPHABET;
  const limit = Math.floor(256 / alphabet.length) * alphabet.length;
  const bytes = new Uint8Array(len * 2);
  let out = "";
  while (out.length < len) {
    crypto.getRandomValues(bytes);
    for (const b of bytes) {
      if (b < limit) {
        out += alphabet[b % alphabet.length];
        if (out.length === len) break;
      }
    }
  }
  return out;
}

function sanitizeFilename(raw) {
  let name = String(raw || "")
    .replace(/\\/g, "/")
    .split("/")
    .pop()
    .replace(/[\u0000-\u001f\u007f]/g, "")
    .trim();
  if (!name || name === "." || name === "..") name = "file";
  return name.slice(0, 180);
}

function decodeURIComponentSafe(s) {
  try { return decodeURIComponent(s); } catch { return s; }
}

function timingSafeEqual(a, b) {
  const enc = new TextEncoder();
  const ab = enc.encode(String(a));
  const bb = enc.encode(String(b));
  if (ab.length !== bb.length) return false;
  if (crypto.subtle.timingSafeEqual) {
    return crypto.subtle.timingSafeEqual(ab, bb);
  }
  let diff = 0;
  for (let i = 0; i < ab.length; i++) diff |= ab[i] ^ bb[i];
  return diff === 0;
}

async function getShareRow(env, token) {
  return (await env.DB.prepare(
    "SELECT token, revoke_token, object_key, filename, size, created_at, expires_at, revoked, object_deleted, downloads, provider, connection_id FROM shares WHERE token = ?1"
  ).bind(token).first()) ?? null;
}

async function allowUpload(env, cfg, install, ip, now) {
  const windowStart = now - cfg.rateWindowMs;
  const count = await env.DB.prepare(
    "SELECT COUNT(*) AS c FROM shares WHERE created_at > ?1 AND (owner_install_id = ?2 OR source_ip = ?3)"
  ).bind(windowStart, install ?? "", ip).first("c");
  return Number(count ?? 0) < cfg.rateLimitUploads;
}

function publicOrigin(cfg, request) {
  if (cfg.publicBaseUrl) return cfg.publicBaseUrl;
  return new URL(request.url).origin;
}

async function deleteObjectQuietly(env, key) {
  try { return await makeStorage(env).delete(key); } catch { return false; } // legacy Supabase only
}

/** Provider-aware storage for a share row (BYO drive / mock / legacy supabase). */
async function storageForShare(env, row) {
  const provider = row.provider || "supabase";
  if (provider === "mock") return makeMockStorage(env);
  if (provider === "drive") {
    const conn = await env.DB.prepare("SELECT * FROM connections WHERE id = ?1")
      .bind(row.connection_id || "").first();
    if (!conn) return null; // connection lost: keep the row, retries via cron
    return makeDriveStorage(env, conn);
  }
  return makeStorage(env); // legacy supabase
}

/** Provider-aware best-effort delete for a share row. */
async function deleteShareObjectQuietly(env, row) {
  try {
    const storage = await storageForShare(env, row);
    if (!storage) return false;
    return await storage.delete(row.object_key);
  } catch { return false; }
}

/** Latest successful cloud connection for an install id (or null). */
async function latestConnection(env, install, provider) {
  if (!install) return null;
  return env.DB.prepare(
    "SELECT * FROM connections WHERE owner_install_id = ?1 AND provider = ?2 ORDER BY created_at DESC LIMIT 1"
  ).bind(install, provider).first();
}

// Bytes currently held by live (not yet deleted) legacy Supabase share rows.
// BYO (drive/mock) rows hold no bytes inside our infra, so they are excluded.
async function liveStorageBytes(env) {
  const row = await env.DB.prepare(
    "SELECT COALESCE(SUM(size), 0) AS b FROM shares WHERE object_deleted = 0 AND provider = 'supabase'"
  ).first("b");
  return Number(row ?? 0);
}

const STORAGE_RETRY_AFTER = "600"; // cron runs every 10 minutes

function throwStorageFull() {
  throw new ApiError(
    507,
    "storage_full",
    "Server storage is full. Space frees automatically as older links expire — try again in a few minutes.",
    { "Retry-After": STORAGE_RETRY_AFTER }
  );
}

// Last-resort self-healing: if storage is over budget, force-delete the oldest
// live objects (their links become 410 "no longer available") until we are back
// under budget. Keeps the deployment inside the R2 free tier without billing.
async function enforceStorageBudget(env, cfg, now) {
  if (cfg.maxStorageBytes <= 0) return 0;
  let usage = await liveStorageBytes(env);
  if (usage <= cfg.maxStorageBytes) return 0;
  let freed = 0;
  while (usage - freed > cfg.maxStorageBytes) {
    const oldest = await env.DB.prepare(
      "SELECT token, object_key, size FROM shares WHERE object_deleted = 0 ORDER BY created_at ASC, token ASC LIMIT 50"
    ).all();
    const rows = oldest.results || [];
    if (rows.length === 0) break;
    const before = freed;
    for (const r of rows) {
      // Mark the row only after a successful blob delete: a failed delete must
      // stay counted in the budget (and be retried next cron), never orphaned.
      const gone = await deleteObjectQuietly(env, r.object_key);
      if (gone) {
        await env.DB.prepare(
          "UPDATE shares SET object_deleted = 1, deleted_at = ?2 WHERE token = ?1"
        ).bind(r.token, now).run();
        freed += Number(r.size) || 0;
      }
      if (usage - freed <= cfg.maxStorageBytes) return freed;
    }
    if (freed === before) break; // storage failures: retry next cron, don't spin
  }
  return freed;
}

function errorFor(e, apiPath) {
  if (e instanceof ApiError) {
    return apiPath
      ? json({ error: { code: e.code, message: e.message } }, e.status, e.headers || {})
      : html(errorPage({ status: e.status, title: titleFor(e.code), message: e.message }), e.status);
  }
  console.log("cliplink error:", String((e && e.stack) || e));
  const message = "Unexpected server error.";
  return apiPath
    ? json({ error: { code: "internal", message } }, 500)
    : html(errorPage({ status: 500, title: "Something went wrong", message }), 500);
}

function titleFor(code) {
  switch (code) {
    case "expired": return "Link expired";
    case "revoked": return "Link revoked";
    case "unknown_share": return "Link not found";
    default: return "Link unavailable";
  }
}

// ---------------------------------------------------------------- handlers

async function handleUpload(request, env, cfg, ctx) {
  const parsed = new URL(request.url);
  if (parsed.protocol !== "https:" && !PLAIN_HTTP_HOSTS.has(parsed.hostname)) {
    throw new ApiError(403, "https_required", "Uploads must use HTTPS in production.");
  }

  const now = Date.now();
  const installHeader = request.headers.get("X-ClipLink-Install") || "";
  const install = INSTALL_REGEX.test(installHeader) ? installHeader : null;
  const ip = (request.headers.get("CF-Connecting-IP")
    || (request.headers.get("X-Forwarded-For") || "").split(",")[0].trim()
    || "");

  const rawLength = Number.parseInt(request.headers.get("Content-Length") || "", 10);
  if (!Number.isFinite(rawLength)) {
    throw new ApiError(411, "length_required", "A Content-Length header is required.");
  }
  if (rawLength > cfg.maxFileBytes) {
    throw new ApiError(413, "file_too_large", `Files up to ${humanBytes(cfg.maxFileBytes)} are accepted.`);
  }
  if (rawLength < 1) {
    throw new ApiError(400, "empty_file", "Empty files are not accepted.");
  }
  if (!request.body) {
    throw new ApiError(400, "empty_body", "A request body is required.");
  }
  if (!(await allowUpload(env, cfg, install, ip, now))) {
    const retryAfter = Math.max(1, Math.ceil(cfg.rateWindowMs / 1000));
    throw new ApiError(429, "rate_limited", "Upload rate limit reached. Try again later.", { "Retry-After": String(retryAfter) });
  }

  const filename = sanitizeFilename(decodeURIComponentSafe(request.headers.get("X-ClipLink-Filename") || ""));
  const expiresAt = now + cfg.expiryMs;

  // BYO storage (drive/mock): upload to the OWNER'S cloud first, then record.
  if (cfg.storageProvider !== "supabase") {
    return byoUpload(request, env, cfg, { install, ip, filename, rawLength, now, expiresAt });
  }

  // Storage budget: never accept an upload that would push total stored bytes
  // past the configured budget (507 instead of silently exceeding the free tier).
  if (cfg.maxStorageBytes > 0) {
    const usage = await liveStorageBytes(env);
    if (usage + rawLength > cfg.maxStorageBytes) throwStorageFull();
  }

  // Insert metadata first; on (astronomically unlikely) token collision, retry
  // with a fresh token. If the upload subsequently fails the row is removed so
  // no dead "valid-looking" link lingers.
  let token = null;
  let revokeToken = null;
  for (let attempt = 0; attempt < 5; attempt++) {
    token = randomToken(cfg.tokenLength);
    revokeToken = randomToken(REVOKE_TOKEN_LENGTH);
    try {
      await env.DB.prepare(
        `INSERT INTO shares
           (token, revoke_token, object_key, filename, size, created_at, expires_at,
            revoked, object_deleted, owner_install_id, source_ip, downloads)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 0, 0, ?8, ?9, 0)`
      ).bind(token, revokeToken, `shares/${token}/${filename}`, filename, rawLength, now, expiresAt, install, ip).run();
      break;
    } catch (e) {
      if (/UNIQUE/i.test(String(e && e.message))) continue;
      throw e;
    }
  }
  const objectKey = `shares/${token}/${filename}`;

  // Stream the request body straight into storage (single PUT; atomic on success).
  let put;
  try {
    put = await makeStorage(env).put(objectKey, request.body, rawLength);
  } catch (e) {
    await env.DB.prepare("DELETE FROM shares WHERE token = ?1").bind(token).run();
    throw new ApiError(502, "storage_error", `Could not store the file. (${String(e && e.message)})`);
  }

  if (put.size > cfg.maxFileBytes) {
    await deleteObjectQuietly(env, objectKey);
    await env.DB.prepare("UPDATE shares SET revoked = 1, object_deleted = 1, deleted_at = ?2 WHERE token = ?1")
      .bind(token, now).run();
    throw new ApiError(413, "file_too_large", `Files up to ${humanBytes(cfg.maxFileBytes)} are accepted.`);
  }
  if (put.size === 0) {
    await deleteObjectQuietly(env, objectKey);
    await env.DB.prepare("DELETE FROM shares WHERE token = ?1").bind(token).run();
    throw new ApiError(400, "empty_file", "Empty files are not accepted.");
  }
  if (put.size !== rawLength) {
    await env.DB.prepare("UPDATE shares SET size = ?2 WHERE token = ?1").bind(token, put.size).run();
  }

  const url = `${publicOrigin(cfg, request)}/s/${token}`;
  return json(
    { url, token, filename, size: put.size, expiresAt, expiresInHours: Math.round(cfg.expiryMs / 3600000), revokeToken },
    201
  );
}

/** BYO path (drive/mock): files land in the OWNER'S cloud; the Worker stores
 *  metadata only. Guest (connection-less) shares exist only in the dev mock. */
async function byoUpload(request, env, cfg, u) {
  const provider = cfg.storageProvider; // "drive" | "mock"
  let connection = await latestConnection(env, u.install, provider);
  if (!connection && provider === "mock" && cfg.allowGuestShares) {
    connection = { id: "", refresh_token: "", access_token: null, access_expires_at: 0 };
  }
  if (!connection) {
    const hintText = provider === "drive"
      ? "Connect Google Drive first: ClipLink menu-bar icon → Connect Google Drive."
      : "This storage provider requires a connected account.";
    throw new ApiError(403, provider === "drive" ? "drive_not_connected" : "not_connected", hintText);
  }

  const storage = provider === "drive" ? makeDriveStorage(env, connection) : makeMockStorage(env);

  for (let attempt = 0; attempt < 5; attempt++) {
    const token = randomToken(cfg.tokenLength);
    const revokeToken = randomToken(REVOKE_TOKEN_LENGTH);
    let put;
    try {
      // drive: objectKey is the human filename; the Drive *file id* comes back.
      // mock: objectKey doubles as the blob table key (token-based).
      const objectKey = provider === "drive" ? u.filename : `mock:${token}`;
      put = await storage.put(objectKey, request.body, u.rawLength);
    } catch (e) {
      const status = e instanceof StorageError && e.status === 403 ? 403 : 502;
      throw new ApiError(status, "storage_error", `Could not store the file in your ${provider === "drive" ? "Google Drive" : "storage"}. (${String(e && e.message)})`);
    }
    const objectKey = provider === "drive" ? (put.fileId || "") : `mock:${token}`;

    try {
      await env.DB.prepare(
        `INSERT INTO shares
           (token, revoke_token, object_key, filename, size, created_at, expires_at,
            revoked, object_deleted, owner_install_id, source_ip, downloads, provider, connection_id)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 0, 0, ?8, ?9, 0, ?10, ?11)`
      ).bind(token, revokeToken, objectKey, u.filename, put.size, u.now, u.expiresAt, u.install, u.ip, provider, connection.id).run();
    } catch (e) {
      if (/UNIQUE/i.test(String(e && e.message))) {
        // collision: remove the just-uploaded file and try a fresh token
        try { await storage.delete(objectKey); } catch { /* best effort */ }
        continue;
      }
      try { await storage.delete(objectKey); } catch { /* best effort */ }
      throw e;
    }

    if (put.size !== u.rawLength) {
      await env.DB.prepare("UPDATE shares SET size = ?2 WHERE token = ?1").bind(token, put.size).run();
    }

    const url = `${publicOrigin(cfg, request)}/s/${token}`;
    return json(
      { url, token, filename: u.filename, size: put.size, expiresAt: u.expiresAt, expiresInHours: Math.round(cfg.expiryMs / 3600000), revokeToken },
      201
    );
  }
  throw new ApiError(500, "token_collision", "Could not allocate a unique token; try again.");
}

async function shareStatus(env, token) {
  const row = await getShareRow(env, token);
  if (!row) throw new ApiError(404, "unknown_share", "This link does not exist (or has already been purged).");
  if (row.revoked) throw new ApiError(410, "revoked", "This link has been revoked by its owner.");
  if (row.expires_at <= Date.now()) throw new ApiError(410, "expired", "This link has expired.");
  if (row.object_deleted) throw new ApiError(410, "gone", "This file is no longer available.");
  return row;
}

function handleLimits(cfg, env) {
  return json({
    maxFileBytes: cfg.maxFileBytes,
    maxFileMB: Math.floor(cfg.maxFileBytes / (1024 * 1024)),
    expiryHours: +(cfg.expiryMs / 3600000).toFixed(4),
    rateLimitUploads: cfg.rateLimitUploads,
    rateWindowMinutes: Math.round(cfg.rateWindowMs / 60000),
    storageBudgetBytes: cfg.maxStorageBytes,
    storageProvider: cfg.storageProvider,
    driveConfigured: cfg.driveConfigured,
  });
}

// -------------------------------------------------------- BYO connect flow

const CONNECT_HTML = (title, detail, ok) => `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>${title} · ClipLink</title>
<style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#0e1016;color:#e8eaf1;
font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;line-height:1.6;text-align:center}
.card{width:min(420px,90vw);background:#161a22;border:1px solid #262c3a;border-radius:18px;padding:32px}
h1{font-size:18px;margin:0 0 8px}.big{font-size:34px;margin:0 0 14px}.det{font-size:14px;color:#9aa3b5}</style></head>
<body><div class="card"><div class="big">${ok ? "✅" : "⚠️"}</div>
<h1>${title}</h1><div class="det">${detail}</div>
<p style="font-size:12px;color:#6b7280;margin-top:18px">You can close this window and return to ClipLink.</p></div></body></html>`;

const OAUTH_SESSION_TTL_MS = 15 * 60 * 1000;

/** App asks for a fresh connect URL (and a secret state to poll for). */
async function handleConnectStart(request, env, cfg) {
  if (!cfg.driveConfigured) {
    throw new ApiError(503, "drive_not_configured", "Google Drive sign-in is not configured on this backend yet.");
  }
  const now = Date.now();
  const state = newId(24);
  const verifier = newId(64);
  const install = request.headers.get("X-ClipLink-Install") || "";
  await env.DB.prepare(
    "INSERT INTO oauth_sessions (state, code_verifier, owner_install_id, created_at) VALUES (?1, ?2, ?3, ?4)"
  ).bind(state, verifier, INSTALL_REGEX.test(install) ? install : null, now).run();
  // opportunistic cleanup of expired sessions
  await env.DB.prepare("DELETE FROM oauth_sessions WHERE created_at < ?1").bind(now - OAUTH_SESSION_TTL_MS).run();
  const authorizeUrl = await buildAuthorizeUrl(env, publicOrigin(cfg, request), state, verifier);
  return json({ provider: "drive", authorizeUrl, state, expiresInMs: OAUTH_SESSION_TTL_MS });
}

/** App polls: once a connection exists for the session's install, done. */
async function handleConnectPoll(request, env, url) {
  const state = url.searchParams.get("state") || "";
  if (!/^[A-Za-z0-9-]{16,64}$/.test(state)) {
    throw new ApiError(400, "invalid_state", "Malformed connect state.");
  }
  const session = await env.DB.prepare("SELECT * FROM oauth_sessions WHERE state = ?1").bind(state).first();
  if (!session) return json({ connected: false, expired: true });
  if (Date.now() - session.created_at > OAUTH_SESSION_TTL_MS) {
    return json({ connected: false, expired: true });
  }
  const conn = await latestConnection(env, session.owner_install_id, "drive");
  if (conn && conn.created_at >= session.created_at - 2000) {
    await env.DB.prepare("DELETE FROM oauth_sessions WHERE state = ?1").bind(state).run();
    const email = await revealAccountEmail(env, conn.account_label);
    return json({ connected: true, provider: "drive", connectionId: conn.id, email });
  }
  return json({ connected: false });
}

/** Google redirects here with the one-time code + our state. */
async function handleDriveCallback(request, env, cfg, url) {
  const close = (title, detail, ok) => new Response(
    CONNECT_HTML(title, detail, ok),
    { headers: { "content-type": "text/html; charset=utf-8", "x-content-type-options": "nosniff" } }
  );
  const err = url.searchParams.get("error");
  const state = url.searchParams.get("state") || "";
  const code = url.searchParams.get("code") || "";
  if (err || !state || !code) {
    return close("Connection failed", url.searchParams.get("error") || "Missing code or state.", false);
  }
  const session = await env.DB.prepare("SELECT * FROM oauth_sessions WHERE state = ?1").bind(state).first();
  if (!session || Date.now() - session.created_at > OAUTH_SESSION_TTL_MS) {
    return close("Link expired", "The connect session is no longer valid — start again from ClipLink.", false);
  }

  let tokens;
  try {
    tokens = await exchangeCode(env, {
      code, verifier: session.code_verifier,
      redirectUri: `${publicOrigin(cfg, request)}/oauth/drive/callback`,
    });
  } catch (e) {
    await env.DB.prepare("DELETE FROM oauth_sessions WHERE state = ?1").bind(state).run();
    return close("Connection failed", String((e && e.message) || e), false);
  }
  if (!tokens.access_token) {
    await env.DB.prepare("DELETE FROM oauth_sessions WHERE state = ?1").bind(state).run();
    return close("Connection failed", "Google did not grant an access token — try connecting again.", false);
  }
  const email = await fetchAccountEmail(tokens.access_token).catch(() => null);

  // If Google withheld a refresh token (re-consent edge case), fall back to the
  // previous connection's refresh token so the flow never bricks the account.
  let refreshToken = tokens.refresh_token || "";
  if (!refreshToken) {
    const previous = await env.DB.prepare(
      "SELECT refresh_token FROM connections WHERE owner_install_id = ?1 AND provider = 'drive' ORDER BY created_at DESC LIMIT 1"
    ).bind(session.owner_install_id || "").first("refresh_token");
    refreshToken = previous || "";
  }
  if (!refreshToken) {
    await env.DB.prepare("DELETE FROM oauth_sessions WHERE state = ?1").bind(state).run();
    return close("Connection failed", "No long-lived refresh token was granted — try connecting again.", false);
  }

  const sealed = await sealConnection(env, tokens, email);
  const existing = await env.DB.prepare(
    "SELECT id FROM connections WHERE owner_install_id = ?1 AND provider = 'drive' ORDER BY created_at DESC LIMIT 1"
  ).bind(session.owner_install_id || "").first("id");

  const now = Date.now();
  if (existing) {
    await env.DB.prepare(
      "UPDATE connections SET refresh_token = ?1, account_label = ?2, access_token = ?3, access_expires_at = ?4 WHERE id = ?5"
    ).bind(sealed.refresh_token, sealed.account_label, sealed.access_token, sealed.access_expires_at, existing).run();
  } else {
    await env.DB.prepare(
      "INSERT INTO connections (id, provider, refresh_token, account_label, owner_install_id, created_at, access_token, access_expires_at) VALUES (?1, 'drive', ?2, ?3, ?4, ?5, ?6, ?7)"
    ).bind(newId(40), sealed.refresh_token, sealed.account_label, session.owner_install_id || null, now,
      sealed.access_token, sealed.access_expires_at).run();
  }
  await env.DB.prepare("DELETE FROM oauth_sessions WHERE state = ?1").bind(state).run();
  return close("Google Drive connected", `${email || "Your account"} is now used as ClipLink's storage. Files will live in YOUR Drive — visible to the app only.`, true);
}

async function handleMetadata(env, token) {
  const row = await shareStatus(env, token);
  return json({
    filename: row.filename,
    size: row.size,
    createdAt: row.created_at,
    expiresAt: row.expires_at,
    downloads: row.downloads,
    downloadPath: `/api/v1/shares/${token}/download`,
  });
}

function parseRange(header) {
  const m = /^bytes=(\d*)-(\d*)$/.exec(header || "");
  if (!m || (m[1] === "" && m[2] === "")) return undefined;
  if (m[1] !== "" && m[2] !== "") {
    const offset = Number.parseInt(m[1], 10);
    const length = Number.parseInt(m[2], 10) - offset + 1;
    if (length <= 0) throw new ApiError(416, "bad_range", "Requested range is not satisfiable.");
    return { offset, length };
  }
  if (m[2] !== "") return { offset: -Number.parseInt(m[2], 10), length: Number.parseInt(m[2], 10) };
  return { offset: Number.parseInt(m[1], 10), length: undefined };
}

async function handleDownload(request, env, token, ctx) {
  const row = await shareStatus(env, token);
  const rangeHeader = request.headers.get("Range");
  if (row.size === 0) throw new ApiError(410, "gone", "This file is no longer available.");
  const range = rangeHeader ? parseRange(rangeHeader) : null;

  const storage = await storageForShare(env, row);
  const object = storage
    ? await storage.getStream(row.object_key, { range: range ? rangeHeader : undefined })
    : null;
  if (!object || object.status === 404) throw new ApiError(410, "gone", "This file is no longer available.");

  const ascii = row.filename.replace(/[^\x20-\x7e]/g, "_").replace(/["\\]/g, "_").slice(0, 120) || "file";
  const headers = {
    "Content-Type": "application/octet-stream",
    "X-Content-Type-Options": "nosniff",
    "Cache-Control": "no-store, max-age=0",
    "Content-Disposition": `attachment; filename="${ascii}"; filename*=UTF-8''${encodeURIComponent(row.filename)}`,
  };
  if (object.size !== undefined) {
    headers["Content-Length"] = String(object.size);
    if (range) headers["Accept-Ranges"] = "bytes";
  }
  if (object.contentRange) headers["Content-Range"] = object.contentRange;

  ctx.waitUntil(
    env.DB.prepare("UPDATE shares SET downloads = downloads + 1 WHERE token = ?1").bind(token).run()
  );
  return new Response(object.body, { status: object.status, headers });
}

async function handleRevoke(request, env, token) {
  const cfg = { adminToken: env.ADMIN_TOKEN || null };
  const row = await getShareRow(env, token);
  if (!row) throw new ApiError(404, "unknown_share", "This link does not exist.");

  const admin = cfg.adminToken
    && timingSafeEqual(request.headers.get("Authorization") || "", `Bearer ${cfg.adminToken}`);
  const revokeToken = request.headers.get("X-ClipLink-Revoke-Token") || "";
  const ownerOk = revokeToken && timingSafeEqual(revokeToken, row.revoke_token);
  if (!admin && !ownerOk) {
    throw new ApiError(401, "unauthorized", "Revocation requires the per-share revoke token or an admin token.");
  }

  const now = Date.now();
  if (!row.revoked && !row.object_deleted) {
    // Revocation is always effective immediately because shareStatus() refuses
    // revoked shares regardless of the object. The file deletion (legacy
    // Supabase object, or the user's Drive copy under BYO) is what we mark
    // object_deleted for — retry via cron if storage was not reachable.
    const gone = await deleteShareObjectQuietly(env, row);
    if (gone) {
      await env.DB.prepare(
        "UPDATE shares SET revoked = 1, object_deleted = 1, deleted_at = ?2 WHERE token = ?1"
      ).bind(token, now).run();
    } else {
      await env.DB.prepare(
        "UPDATE shares SET revoked = 1, deleted_at = ?2 WHERE token = ?1"
      ).bind(token, now).run();
    }
  } else if (!row.revoked) {
    await env.DB.prepare(
      "UPDATE shares SET revoked = 1 WHERE token = ?1"
    ).bind(token).run();
  }
  return json({ ok: true, token, revoked: true });
}

async function cleanupExpired(env, cfg) {
  const now = Date.now();
  // Retry object deletion for (a) expired shares and (b) revoked shares whose
  // deletion failed at revoke time — under BYO a revoked file must leave the
  // user's Drive promptly, not wait out the link's remaining lifetime.
  const expired = await env.DB.prepare(
    "SELECT token, object_key, provider, connection_id FROM shares WHERE (expires_at < ?1 OR revoked = 1) AND object_deleted = 0 LIMIT 200"
  ).bind(now).all();
  let deleted = 0;
  for (const r of expired.results || []) {
    // Only mark when the stored copy is really gone — a Drive/Supabase row
    // stays budget-accounted (legacy) or retried (BYO) until deleted.
    const gone = await deleteShareObjectQuietly(env, r);
    if (gone) {
      await env.DB.prepare(
        "UPDATE shares SET object_deleted = 1, deleted_at = ?2 WHERE token = ?1"
      ).bind(r.token, now).run();
      deleted++;
    }
  }
  // Purge old metadata rows entirely — but only once their blob was handled
  // (object_deleted=1). If a blob still exists, keep the row so the cron keeps
  // trying; further requests become plain 404s.
  await env.DB.prepare(
    "DELETE FROM shares WHERE expires_at < ?1 AND object_deleted = 1"
  ).bind(now - cfg.retentionMs).run();
  return deleted;
}

// ---------------------------------------------------------------- router

export default {
  async fetch(request, env, ctx) {
    const cfg = readConfig(env);
    const url = new URL(request.url);
    const path = url.pathname;
    const isApi = path.startsWith("/api/");
    try {
      const parts = path.split("/").filter(Boolean);

      if (path === "/healthz" && request.method === "GET") {
        return json({ ok: true, service: "cliplink", time: Date.now() });
      }
      if (path === "/api/v1/limits" && request.method === "GET") {
        return handleLimits(cfg, env);
      }
      if (path === "/api/v1/providers/drive/authorize" && request.method === "GET") {
        return await handleConnectStart(request, env, cfg);
      }
      if (path === "/api/v1/providers/drive/poll" && request.method === "GET") {
        return await handleConnectPoll(request, env, url);
      }
      if (path === "/oauth/drive/callback" && request.method === "GET") {
        return await handleDriveCallback(request, env, cfg, url);
      }
      if (path === "/api/v1/shares") {
        if (request.method !== "POST") {
          throw new ApiError(405, "method_not_allowed", "Use POST to create a share.", { Allow: "POST" });
        }
        return await handleUpload(request, env, cfg, ctx);
      }
      if (parts.length === 4 && parts[0] === "api" && parts[1] === "v1" && parts[2] === "shares") {
        const token = decodeURIComponentSafe(parts[3]);
        if (!TOKEN_REGEX.test(token)) throw new ApiError(400, "invalid_token", "Malformed share token.");
        if (request.method === "GET") return await handleMetadata(env, token);
        if (request.method === "DELETE") return await handleRevoke(request, env, token);
        throw new ApiError(405, "method_not_allowed", "Use GET or DELETE.", { Allow: "GET, DELETE" });
      }
      if (parts.length === 5 && parts[0] === "api" && parts[1] === "v1" && parts[2] === "shares" && parts[4] === "download") {
        if (request.method !== "GET") {
          throw new ApiError(405, "method_not_allowed", "Use GET to download.", { Allow: "GET" });
        }
        const token = decodeURIComponentSafe(parts[3]);
        if (!TOKEN_REGEX.test(token)) throw new ApiError(400, "invalid_token", "Malformed share token.");
        return await handleDownload(request, env, token, ctx);
      }
      if (parts.length === 2 && parts[0] === "s") {
        if (request.method !== "GET") throw new ApiError(405, "method_not_allowed", "Use GET.", { Allow: "GET" });
        const token = decodeURIComponentSafe(parts[1]);
        if (!TOKEN_REGEX.test(token)) throw new ApiError(400, "invalid_token", "Malformed share token.");
        const row = await shareStatus(env, token);
        return html(sharePage({ filename: row.filename, size: row.size, expiresAt: row.expires_at, now: Date.now(), token }));
      }
      throw new ApiError(404, "not_found", "Unknown path.");
    } catch (e) {
      return errorFor(e, isApi);
    }
  },

  async scheduled(event, env, ctx) {
    const cfg = readConfig(env);
    const now = Date.now();
    const deleted = await cleanupExpired(env, cfg);
    const evicted = await enforceStorageBudget(env, cfg, now);
    console.log(`cliplink cleanup: expired objects deleted: ${deleted}; evicted by storage budget: ${evicted}`);
    // Keepalive: free Supabase projects pause after ~7 days without traffic.
    // One cheap REST call per cron keeps the project (and thus blob storage) live.
    if (env.SUPABASE_URL) {
      try { await storageKeepAlive(env); } catch (e) {
        console.log("cliplink keepalive failed:", String((e && e.message) || e));
      }
    }
  },
};
