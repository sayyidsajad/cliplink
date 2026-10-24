/**
 * Blob storage backed by Supabase Storage (cardless free tier), replacing R2.
 *
 * Exposes the small surface the worker needs: put / delete / getStream.
 * All calls authenticate with SUPABASE_SERVICE_KEY, which lives only in
 * Worker secrets / .dev.vars — never in the repo or the Mac app.
 *
 * Downloads stream through the worker: we mint a short-lived signed URL,
 * fetch it, and pipe the body back — so expiry/revocation checks stay
 * authoritative and the service key never reaches a client.
 */

const SIGN_TTL_SECONDS = 300; // signed URL lives 5 min; only the worker sees it

export class StorageError extends Error {
  constructor(status, message) {
    super(String(message || "storage error"));
    this.status = status;
  }
}

function storageConfig(env) {
  const url = String(env.SUPABASE_URL || "").trim().replace(/\/+$/, "");
  const key = String(env.SUPABASE_SERVICE_KEY || "").trim();
  const bucket = String(env.STORAGE_BUCKET || "").trim();
  if (!url || !key || !bucket) {
    throw new StorageError(500, "storage_not_configured: SUPABASE_URL / SUPABASE_SERVICE_KEY / STORAGE_BUCKET missing");
  }
  return { url, key, bucket };
}

function encodeObjectPath(key) {
  return key.split("/").map(encodeURIComponent).join("/");
}

function headers(cfg) {
  return { Authorization: `Bearer ${cfg.key}` };
}

async function api(cfg, path, init) {
  const res = await fetch(`${cfg.url}/storage/v1${path}`, {
    ...init,
    headers: { ...headers(cfg), ...(init.headers || {}) },
  });
  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new StorageError(res.status, text.slice(0, 300));
  }
  return res;
}

export function makeStorage(env) {
  const cfg = storageConfig(env);
  const obj = (key) => `/object/${cfg.bucket}/${encodeObjectPath(key)}`;

  return {
    /**
     * Streams raw bytes up to storage. Supabase does not return the object
     * size on upload, so the caller passes the verified Content-Length.
     */
    async put(key, body, expectedSize) {
      await api(cfg, obj(key), {
        method: "POST",
        body,
        headers: { "x-upsert": "true", "Content-Type": "application/octet-stream" },
      });
      return { size: expectedSize };
    },

    /** Best-effort delete; missing objects must not throw. */
    async delete(key) {
      try { await api(cfg, obj(key), { method: "DELETE" }); } catch { /* best-effort */ }
    },

    /**
     * Returns { body: ReadableStream, status, size } for the object.
     * HTTP Range requests are forwarded so partial downloads keep working.
     */
    async getStream(key, { range } = {}) {
      const signRes = await api(cfg, `/object/sign/${cfg.bucket}/${encodeObjectPath(key)}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ expiresIn: SIGN_TTL_SECONDS }),
      });
      const { signedURL } = await signRes.json();
      if (!signedURL) throw new StorageError(500, "sign_failed");

      const upstream = await fetch(`${cfg.url}/storage/v1${signedURL}`, {
        headers: range ? { Range: range } : {},
      });
      if (upstream.status === 404) return null;
      if (!upstream.ok) {
        throw new StorageError(upstream.status, `signed fetch failed (${upstream.status})`);
      }
      const len = upstream.headers.get("Content-Length");
      return {
        body: upstream.body,
        status: upstream.status === 206 ? 206 : 200,
        size: len ? Number(len) : undefined,
        contentRange: upstream.headers.get("Content-Range"),
      };
    },
  };
}

/**
 * Tiny keepalive: Supabase pauses free projects after ~7 days of inactivity,
 * which would silently break uploads. One cheap REST call inside the cron
 * (every 10 min) keeps the project awake.
 */
export async function storageKeepAlive(env) {
  const cfg = storageConfig(env);
  const res = await fetch(`${cfg.url}/rest/v1/shares?select=token&limit=1`, {
    headers: { apikey: cfg.key, Authorization: `Bearer ${cfg.key}` },
  });
  if (!res.ok) throw new StorageError(res.status, "keepalive failed");
  return res.status;
}
