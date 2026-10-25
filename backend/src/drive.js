/**
 * Blob storage backed by **the user's own Google Drive** (BYO storage).
 *
 * The operator's infra holds **zero file bytes**. Files land in the user's
 * Drive via a resumable upload streamed straight from the HTTP request body;
 * downloads are streamed back through the Worker as a proxy (so short links,
 * expiry checks, and revocations stay authoritative); the cron deletes the
 * user's copy when a link expires — even if the user's Mac is offline.
 *
 * OAuth: the app opens `authorizeUrl(state)`; Google redirects the user back
 * to /oauth/drive/callback; the Worker exchanges the code (PKCE) and stores
 * the refresh token **sealed** (crypto.js) in D1. The Mac app only receives
 * the connection id + account email — the token itself transits nowhere else.
 *
 * Scope: https://www.googleapis.com/auth/drive.file — the app can only ever
 * see files *it created*; the rest of the user's Drive is invisible.
 */

import { sealText, openText } from "./crypto.js";

const CHUNK = 8 * 1024 * 1024; // 8 MiB — must be a multiple of 256 KiB
const ACCESS_TOKEN_SAFETY_MS = 5 * 60 * 1000; // refresh 5 min before real expiry

export class StorageError extends Error {
  constructor(status, message) {
    super(String(message || "storage error"));
    this.status = status;
  }
}

export const DRIVE_AUTHORIZE = "https://accounts.google.com/o/oauth2/v2/auth";
export const DRIVE_TOKEN = "https://oauth2.googleapis.com/token";
export const DRIVE_SCOPE = "openid email https://www.googleapis.com/auth/drive.file";

export function driveConfig(env) {
  const clientId = String(env.DRIVE_CLIENT_ID || "").trim();
  const clientSecret = String(env.DRIVE_CLIENT_SECRET || "").trim();
  if (!clientId || !clientSecret) {
    throw new StorageError(500, "drive_not_configured: DRIVE_CLIENT_ID / DRIVE_CLIENT_SECRET missing");
  }
  return { clientId, clientSecret };
}

export function newId(len = 40) {
  const alphabet = "abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const limit = Math.floor(256 / alphabet.length) * alphabet.length;
  let out = "";
  while (out.length < len) {
    const bytes = new Uint8Array(len * 2);
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

export async function codeChallenge(verifier) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
  return btoa(String.fromCharCode(...new Uint8Array(digest)))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** Builds the Google consent URL. `origin` is the public Worker origin. */
export async function buildAuthorizeUrl(env, origin, state, verifier) {
  const cfg = driveConfig(env);
  const params = new URLSearchParams({
    client_id: cfg.clientId,
    redirect_uri: `${origin}/oauth/drive/callback`,
    response_type: "code",
    scope: DRIVE_SCOPE,
    access_type: "offline",
    prompt: "consent",
    include_granted_scopes: "false",
    state,
    code_challenge: await codeChallenge(verifier),
    code_challenge_method: "S256",
  });
  return `${DRIVE_AUTHORIZE}?${params}`;
}

async function tokenRequest(env, body) {
  const cfg = driveConfig(env);
  const res = await fetch(DRIVE_TOKEN, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ client_id: cfg.clientId, client_secret: cfg.clientSecret, ...body }),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new StorageError(502, `drive_token_error: ${data.error || res.status}`);
  }
  return data; // { access_token, expires_in, refresh_token?, id_token? }
}

/** Exchanges the OAuth one-time code for tokens (PKCE verifier required). */
export async function exchangeCode(env, { code, verifier, redirectUri }) {
  return tokenRequest(env, {
    code,
    grant_type: "authorization_code",
    redirect_uri: redirectUri,
    code_verifier: verifier,
  });
}

export async function fetchAccountEmail(accessToken) {
  const res = await fetch("https://openidconnect.googleapis.com/v1/userinfo", {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  if (!res.ok) return null;
  const info = await res.json().catch(() => ({}));
  return info.email || null;
}

/** The per-connection storage surface (mirrors supabase.js: put/getStream/delete). */
export function makeDriveStorage(env, connectionRecord) {
  const row = connectionRecord; // full D1 row from `connections`

  async function accessToken() {
    const now = Date.now();
    if (row.access_token && row.access_expires_at && now < row.access_expires_at - ACCESS_TOKEN_SAFETY_MS) {
      const cached = await openText(env, row.access_token);
      if (cached) return cached;
    }
    const refresh = await openText(env, row.refresh_token);
    if (!refresh) throw new StorageError(500, "connection_decryption_failed");
    const tokens = await tokenRequest(env, { refresh_token: refresh, grant_type: "refresh_token" });
    await env.DB.prepare(
      "UPDATE connections SET access_token = ?1, access_expires_at = ?2 WHERE id = ?3"
    ).bind(
      await sealText(env, tokens.access_token),
      now + Number(tokens.expires_in || 3600) * 1000,
      row.id
    ).run();
    row.access_token = await sealText(env, tokens.access_token);
    row.access_expires_at = now + Number(tokens.expires_in || 3600) * 1000;
    return tokens.access_token;
  }

  async function driveApi(path, init = {}) {
    const at = await accessToken();
    const res = await fetch(path, { ...init, headers: { Authorization: `Bearer ${at}`, ...(init.headers || {}) } });
    if (res.status === 401) {
      // force a refresh once, then retry
      row.access_token = null; row.access_expires_at = 0;
      const at2 = await accessToken();
      return fetch(path, { ...init, headers: { Authorization: `Bearer ${at2}`, ...(init.headers || {}) } });
    }
    return res;
  }

  return {
    provider: "drive",

    /**
     * Streams the request body into the user's Drive in resumable 8 MiB chunks
     * (keeps Worker memory bounded; final chunk may be smaller). Returns the
     * Drive file id + size; the caller stores fileId as the share's object key.
     */
    async put(name, body, expectedSize) {
      let at = await accessToken();
      const sessionRes = await fetch(
        "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id",
        {
          method: "POST",
          headers: {
            Authorization: `Bearer ${at}`,
            "Content-Type": "application/json; charset=UTF-8",
            "X-Upload-Content-Type": "application/octet-stream",
            "X-Upload-Content-Length": String(expectedSize),
          },
          body: JSON.stringify({ name, mimeType: "application/octet-stream" }),
        }
      );
      if (!sessionRes.ok) {
        let detail = `drive_session_failed (${sessionRes.status})`;
        const bodyText = await sessionRes.text().catch(() => "");
        if (bodyText) {
          try {
            const parsed = JSON.parse(bodyText);
            const err = parsed.error || {};
            // e.g. 403 { error: { errors: [{reason: "quotaExceeded"}], message: "..." } }
            const reason = (err.errors && err.errors[0] && err.errors[0].reason) || err.status || "";
            detail += reason ? ` [${reason}] ${err.message || ""}` : ` ${bodyText.slice(0, 300)}`;
          } catch {
            detail += ` ${bodyText.slice(0, 300)}`;
          }
        }
        throw new StorageError(sessionRes.status, detail);
      }
      const sessionUrl = sessionRes.headers.get("location");
      if (!sessionUrl) throw new StorageError(502, "drive_session_missing_location");

      let offset = 0;
      const reader = body.getReader();
      let done = false;
      while (true) {
        let chunk = null;
        if (!done) {
          const read = await reader.read();
          done = read.done;
          if (read.value) chunk = read.value;
        }
        if (!chunk) break;
        // coalesce short reads up to CHUNK (except the final one)
        if (chunk.length < CHUNK && !done) {
          const parts = [chunk];
          let len = chunk.length;
          while (len < CHUNK) {
            const r2 = await reader.read();
            done = r2.done;
            if (r2.done) break;
            parts.push(r2.value);
            len += r2.value.length;
          }
          chunk = new Uint8Array(len);
          let p = 0;
          for (const part of parts) { chunk.set(part, p); p += part.length; }
        }
        const isFinal = done || offset + chunk.length >= expectedSize;
        const end = offset + chunk.length - 1;
        const rangeHdr = isFinal
          ? `bytes ${offset}-${end}/${expectedSize}`
          : `bytes ${offset}-${end}/*`;
        const payload = chunk.buffer.slice(chunk.byteOffset, chunk.byteOffset + chunk.byteLength);
        await new Promise((r) => setTimeout(r, 0)); // yield the event loop between chunks
        const onSession = (attempt) => fetch(sessionUrl, {
          method: "PUT",
          headers: {
            Authorization: `Bearer ${attempt.at}`,
            "Content-Range": rangeHdr,
            "Content-Length": String(chunk.byteLength),
          },
          body: payload,
        });
        let res2 = await onSession({ at });
        if (res2.status === 401) { // token expired mid-loop: refresh once and retry the chunk
          row.access_token = null; row.access_expires_at = 0;
          at = await accessToken();
          res2 = await onSession({ at });
        }
        if (res2.status === 308) { offset += chunk.byteLength; if (isFinal) break; continue; } // chunk accepted
        if (!res2.ok && res2.status !== 201 && res2.status !== 200) {
          throw new StorageError(res2.status, `drive_upload_failed (${res2.status})`);
        }
        const file = await res2.json().catch(() => ({}));
        if (!file.id) throw new StorageError(502, "drive_upload_no_id");
        return { size: Number(file.size || expectedSize || offset + chunk.length), fileId: file.id };
      }
      throw new StorageError(502, "drive_upload_stream_ended_early");
    },

    /** Streams bytes back; Range requests are forwarded so partial downloads work. */
    async getStream(fileId, { range } = {}) {
      const res = await driveApi(
        `https://www.googleapis.com/drive/v3/files/${encodeURIComponent(fileId)}?alt=media`,
        { headers: range ? { Range: range } : {} }
      );
      if (res.status === 404 || res.status === 403) return null; // file gone / no access
      if (!res.ok) throw new StorageError(res.status, `drive_fetch_failed (${res.status})`);
      const len = res.headers.get("Content-Length");
      return {
        body: res.body,
        status: res.status === 206 ? 206 : 200,
        size: len ? Number(len) : undefined,
        contentRange: res.headers.get("Content-Range"),
      };
    },

    /** Used by revoke + the expiry cron: deletes the copy in the USER's Drive. */
    async delete(fileId) {
      try {
        const res = await driveApi(
          `https://www.googleapis.com/drive/v3/files/${encodeURIComponent(fileId)}`,
          { method: "DELETE" }
        );
        return res.status === 204 || res.status === 404 || res.status === 410;
      } catch { return false; }
    },
  };
}

/** Convenience for the connect flow: seal refresh token + email for storage. */
export async function sealConnection(env, tokens, email) {
  return {
    refresh_token: await sealText(env, tokens.refresh_token || ""),
    account_label: email ? await sealText(env, email) : null,
    access_token: tokens.access_token ? await sealText(env, tokens.access_token) : null,
    access_expires_at: tokens.expires_in ? Date.now() + Number(tokens.expires_in) * 1000 : 0,
  };
}

export async function revealAccountEmail(env, sealedLabel) {
  return sealedLabel ? openText(env, sealedLabel) : null;
}
