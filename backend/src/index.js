/**
 * ClipLink backend — Cloudflare Worker.
 *
 * Endpoints:
 *   POST   /api/v1/shares                 upload (raw body) -> create public share
 *   GET    /api/v1/limits                 advertised limits (JSON)
 *   GET    /api/v1/shares/:token          share metadata (JSON)
 *   GET    /api/v1/shares/:token/download file download (streams from R2)
 *   DELETE /api/v1/shares/:token          revoke (requires per-share revoke token or admin token)
 *   GET    /s/:token                      human download page
 *   GET    /healthz
 * plus a scheduled job that deletes expired objects.
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
 */

import { sharePage, errorPage, humanBytes } from "./page.js";

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

const json = (data, status = 200, headers = {}) =>
  new Response(JSON.stringify(data, null, 2), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", ...headers },
  });

const html = (body, status = 200) =>
  new Response(body, {
    status,
    headers: { "content-type": "text/html; charset=utf-8", "x-content-type-options": "nosniff" },
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
    "SELECT token, revoke_token, object_key, filename, size, created_at, expires_at, revoked, object_deleted, downloads FROM shares WHERE token = ?1"
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
  try { await env.BUCKET.delete(key); } catch { /* best-effort */ }
}

// Bytes currently held in R2 by live (not yet deleted) share rows.
async function liveStorageBytes(env) {
  const row = await env.DB.prepare(
    "SELECT COALESCE(SUM(size), 0) AS b FROM shares WHERE object_deleted = 0"
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
    for (const r of rows) {
      await deleteObjectQuietly(env, r.object_key);
      await env.DB.prepare(
        "UPDATE shares SET object_deleted = 1, deleted_at = ?2 WHERE token = ?1"
      ).bind(r.token, now).run();
      freed += Number(r.size) || 0;
      if (usage - freed <= cfg.maxStorageBytes) return freed;
    }
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

  // Storage budget: never accept an upload that would push total stored bytes
  // past the configured budget (507 instead of silently exceeding the free tier).
  if (cfg.maxStorageBytes > 0) {
    const usage = await liveStorageBytes(env);
    if (usage + rawLength > cfg.maxStorageBytes) throwStorageFull();
  }

  const filename = sanitizeFilename(decodeURIComponentSafe(request.headers.get("X-ClipLink-Filename") || ""));
  const expiresAt = now + cfg.expiryMs;

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

  // Stream the request body straight into R2 (single PUT; atomic on success).
  let put;
  try {
    put = await env.BUCKET.put(objectKey, request.body, {
      httpMetadata: { contentType: "application/octet-stream" },
      customMetadata: { originalFilename: filename },
    });
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
  });
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
  const range = parseRange(request.headers.get("Range"));
  const object = await env.BUCKET.get(row.object_key, range ? { range } : undefined);
  if (!object) throw new ApiError(410, "gone", "This file is no longer available.");

  const ascii = row.filename.replace(/[^\x20-\x7e]/g, "_").replace(/["\\]/g, "_").slice(0, 120) || "file";
  const headers = {
    "Content-Type": "application/octet-stream",
    "X-Content-Type-Options": "nosniff",
    "Accept-Ranges": "bytes",
    "Cache-Control": "no-store, max-age=0",
    "Content-Disposition": `attachment; filename="${ascii}"; filename*=UTF-8''${encodeURIComponent(row.filename)}`,
  };
  if (object.size !== undefined) headers["Content-Length"] = String(object.size);

  ctx.waitUntil(
    env.DB.prepare("UPDATE shares SET downloads = downloads + 1 WHERE token = ?1").bind(token).run()
  );
  return new Response(object.body, { status: range ? 206 : 200, headers });
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
  if (!row.revoked) {
    await env.BUCKET.delete(row.object_key);
    await env.DB.prepare(
      "UPDATE shares SET revoked = 1, object_deleted = 1, deleted_at = ?2 WHERE token = ?1"
    ).bind(token, now).run();
  }
  return json({ ok: true, token, revoked: true });
}

async function cleanupExpired(env, cfg) {
  const now = Date.now();
  const expired = await env.DB.prepare(
    "SELECT token, object_key FROM shares WHERE expires_at < ?1 AND object_deleted = 0 LIMIT 200"
  ).bind(now).all();
  for (const r of expired.results || []) {
    await deleteObjectQuietly(env, r.object_key);
    await env.DB.prepare(
      "UPDATE shares SET object_deleted = 1, deleted_at = ?2 WHERE token = ?1"
    ).bind(r.token, now).run();
  }
  // Purge old metadata rows entirely; further requests become plain 404s.
  await env.DB.prepare("DELETE FROM shares WHERE expires_at < ?1").bind(now - cfg.retentionMs).run();
  return (expired.results || []).length;
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
  },
};
