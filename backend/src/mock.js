/**
 * Mock blob storage for local/CI testing of the BYO flow (D1-backed so it
 * survives isolate restarts, unlike in-memory maps). Enabled ONLY when
 * MOCK_PROVIDER=1 / STORAGE_PROVIDER=mock — never in production, and guest
 * (connection-less) shares are only allowed in that same dev sandbox.
 */

const enc = new TextEncoder();
const dec = new TextDecoder();

function b64(bytes) {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin);
}

function unB64(s) {
  const bin = atob(s);
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

export function makeMockStorage(env) {
  return {
    provider: "mock",

    async put(key, body, expectedSize) {
      const buf = new Uint8Array(await new Response(body).arrayBuffer());
      await env.DB.prepare(
        "INSERT INTO mock_blobs (token, data) VALUES (?1, ?2) ON CONFLICT(token) DO UPDATE SET data = excluded.data"
      ).bind(key, b64(buf)).run();
      return { size: expectedSize, fileId: key };
    },

    async delete(key) {
      await env.DB.prepare("DELETE FROM mock_blobs WHERE token = ?1").bind(key).run();
      return true;
    },

    async getStream(key, { range } = {}) {
      const row = await env.DB.prepare("SELECT data FROM mock_blobs WHERE token = ?1").bind(key).first("data");
      if (row === undefined || row === null) return null;
      const all = unB64(String(row));
      let slice = all;
      let status = 200;
      let contentRange;
      if (range) {
        const m = /^bytes=(\d*)-(\d*)$/.exec(range) || /^bytes=(\d*)-$/.exec(range);
        const start = Number((m && m[1]) || 0);
        const end = m && m[2] !== "" ? Number(m[2]) : all.length - 1;
        if (start >= all.length) return null;
        slice = all.subarray(start, Math.min(end, all.length - 1) + 1);
        status = 206;
        contentRange = `bytes ${start}-${start + slice.length - 1}/${all.length}`;
      }
      return {
        body: new Response(slice).body,
        status,
        size: slice.length,
        contentRange,
      };
    },
  };
}
