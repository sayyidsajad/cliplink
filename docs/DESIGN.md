# ClipLink — design notes

These notes summarize the key decisions from the PRD implementation.

## Pipeline

1. **Detect** — `ClipboardMonitor` polls the pasteboard (~0.5 s) for
   `public.file-url` entries. State that predates watcher startup is ignored,
   and ClipLink's own clipboard writes are tagged/ignored (no upload loops).
2. **Eligibility** — per downloaded metadata (`/api/v1/limits`): not empty,
   within `maxFileBytes`, not a directory, and not matching a blocked pattern
   (default blocklist includes `id_rsa*`, `*.ssh/*`, `.env*` …, configurable
   via `cliplink.blockedPatterns`). If the limits fetch fails, the last known
   limits are used and a note is surfaced; the file is never uploaded on
   ambiguous state.
3. **Upload** — `UploadClient` streams the file from disk with
   `URLSession.uploadTask(fromFile:)` (raw body, `application/octet-stream`,
   `X-ClipLink-Filename`), with bounded retries/backoff. On any failure the
   clipboard is left untouched.
4. **Replace clipboard** — success writes the share URL (`…/s/<token>` style
   returned by the server) onto the general pasteboard and records the share
   in `LinkStore` (menu history, copy/revoke actions).

## Why raw-body upload (not multipart)

One `PUT`-shaped streaming request keeps memory flat for big files, is dead
simple to parse in Workers (just `request.body` → `R2.put`), avoids multipart
parsing edge cases with binary data, and metadata rides in two headers.

## Server

- **R2 for bytes** → v0.3-era **Supabase Storage for bytes** → since **v0.4,
  BYO: the uploader's own Google Drive for bytes** (PKCE OAuth, sealed refresh
  token, resumable uploads streamed straight off the request body, downloads
  Range-proxied through the Worker — the operator stores zero file bytes);
  **D1** for share metadata and connection records
  (`shares`, `connections`, `oauth_sessions` — see `backend/schema.sql`).
- Every request to a share re-checks `expires_at` / `revoked` → deterministic
  410 or a friendly expired/revoked page at `/s/:token`.
- Cron (`*/10 * * * *`) deletes expired objects (in the user's Drive for BYO
  rows; Supabase for legacy rows), retries deletion for revoked shares, then
  purges rows older than `ROW_RETENTION_DAYS` so the "expired" page can still
  explain itself briefly before disappearing entirely.
- **Storage budget (legacy rows only)**: total stored bytes are capped by
  `MAX_STORAGE_GB`. New uploads past the budget get `507 storage_full`; the
  cron force-evicts the oldest objects when usage overruns (config change or
  race). This keeps a deployment inside the storage free tier with zero
  billing risk; BYO rows hold no bytes on the operator's side and are excluded.
- Rate limiting by `install id` (client-generated, stored for rate limiting
  only) with IP fallback. It is **not** an authentication mechanism.
- Revocation requires the per-share `revoke_token` header or the (optional)
  `ADMIN_TOKEN` admin secret. Nothing embeds secrets in the Mac app.

## Test strategy

- `scripts/test-backend.sh` — curl-level smoke suite (roundtrip, error paths,
  revocation, limits advertised).
- `ClipLinkCLI watch --once` — headless E2E of the clipboard monitor against
  `wrangler dev`, including the blocklist case (copy an `id_rsa*` file and
  confirm it is skipped).
- Launching the packaged `ClipLink.app` binary directly with arg-domain
  overrides (`-cliplink.onboardingDone 1 …`) exercises the real GUI app
  end-to-end: clipboard copy → upload → clipboard replaced → byte-identical
  download → revoke → 410.
  (Note: `open build/ClipLink.app -args …` did not reliably pass the override
  args in testing; run the inner binary directly for e2e overrides.)
- `[env.tiny]` wrangler environment (1 MB / ~12 s expiry / 3 uploads per hour)
  makes expiration and rate-limit paths fast to exercise locally.
