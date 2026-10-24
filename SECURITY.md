# Security policy

ClipLink: a macOS menu-bar app (Swift) + Cloudflare Worker backend + Supabase
Storage for blobs. Reporting a vulnerability: please open a
[security advisory](https://github.com/sayyidsajad/cliplink/security/advisories/new)
or a normal GitHub issue if it is not sensitive. Include reproduction steps.

## Supported versions

| Version | Supported |
|---|---|
| 0.3.x   | ✅ |
| < 0.3.0 | ❌ (upgrade — releases are cheap) |

## What is in scope

- `backend/src/*` — the Cloudflare Worker (upload, share, revoke, download, cron)
- `backend/src/supabase.js` — Supabase Storage client (signed URLs)
- `macapp/Sources/*` — clipboard monitor, upload client, CLI
- `sayyidsajad/cliplink-website` — the static download site

## Guarantees already designed in

- Every link **expires** (24 h default) and every request re-checks expiry/revocation
- Downloads are brokered through short-lived signed URLs — storage is never public
- Revoke tokens are per-share secrets, compared timing-safely
- Total stored bytes are capped server-side; over-budget objects are evicted oldest-first
- Files matching the privacy blocklist (`id_rsa*`, `*.ssh/*`, `.env*`…) are never uploaded
- No cookies, no analytics — backend and website have no tracking of any kind

## Out of scope

- Abuse of the *hosted* free service's rate limits outside the app's intended use
  (the enforcement mechanisms themselves are in scope)
- Issues in third-party platforms: Cloudflare Workers/D1, Supabase, GitHub Pages, Apple macOS

## Distribution honesty note

Released DMGs are **ad-hoc signed** (no paid Apple Developer ID certificate),
which is why macOS shows a first-launch prompt. Binaries are built reproducibly
by the public CI from this repo — review the `release.yml` workflow.
