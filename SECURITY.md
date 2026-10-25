# Security policy

## Reporting a vulnerability

Please open a [security advisory](https://github.com/sayyidsajad/cliplink/security/advisories/new)
or a [normal issue](https://github.com/sayyidsajad/cliplink/issues/new?template=abuse-report.md)
for abuse reports (illegal content, privacy, takedowns). Preferable for
sensitive/urgent matters: e-mail **`sayyidsajada4s@gmail.com`** (public report
mailbox and grievance contact under India's IT Rules 2021). Operating
procedures: see [docs/LEGAL-RUNBOOK.md](docs/LEGAL-RUNBOOK.md).

## Supported versions

| Version | Supported |
|---|---|
| 0.4.x   | ✅ |
| 0.3.x   | ✅ (legacy storage mode) |
| < 0.3.0 | ❌ (upgrade — releases are cheap) |

## What is in scope

- `backend/src/*` — the Cloudflare Worker (connect flow, upload, share, revoke, download, cron)
- `backend/src/drive.js` — Google Drive adapter + OAuth/PKCE client
- `backend/src/crypto.js` — AES-GCM sealing of OAuth tokens at rest
- `backend/src/supabase.js` — legacy Supabase Storage client (v0.3 rows)
- `backend/src/mock.js` — dev/CI mock provider (guest shares; never in prod)
- `macapp/Sources/*` — clipboard monitor, upload client, connect client, CLI
- `sayyidsajad/cliplink-website` — the static download site

## Guarantees already designed in

- Every link **expires** (24 h default) and every request re-checks expiry/revocation
- Downloads are brokered through the Worker — short links and revocations stay
  authoritative; the raw storage file id is never exposed past the share token
- Revoke tokens are per-share secrets, compared timing-safely
- **BYO storage** (v0.4+): file bytes live in the uploader's own Google Drive —
  the backend stores zero file bytes; scope is `drive.file` (the app can only
  see files it created), and the expiry cron deletes the copy **in the user's
  Drive**, including for revoked shares (retried until confirmed deleted)
- OAuth refresh tokens are **AES-GCM sealed in D1** (`enc1:` format in
  `crypto.js`) keyed by the `TOKEN_SECRET` Worker secret — a database read
  leaks no usable tokens; rotation only invalidates sealed rows (reconnect fixes)
- PKCE (S256) on the OAuth flow; the app receives only a connection id +
  display email, never any token
- Legacy rows: signed URLs are short-lived and storage remains private (v0.3 mode)
- Revoke tokens are per-share secrets, compared timing-safely
- Total legacy stored bytes are capped server-side; over-budget objects are evicted oldest-first
- Files matching the privacy blocklist (`id_rsa*`, `*.ssh/*`, `.env*`…) are never uploaded
- No cookies, no analytics — backend and website have no tracking of any kind

## Out of scope

- Abuse of the *hosted* free service's rate limits outside the app's intended use
  (the enforcement mechanisms themselves are in scope)
- Issues in third-party platforms: Cloudflare Workers/D1, Google Drive/OAuth, GitHub Pages, Apple macOS

## Distribution honesty note

Released DMGs are **ad-hoc signed** (no paid Apple Developer ID certificate),
which is why macOS shows a first-launch prompt. Binaries are built reproducibly
by the public CI from this repo — review the `release.yml` workflow.
