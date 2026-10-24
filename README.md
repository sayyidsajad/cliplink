# ClipLink

**Copy a file in Finder → paste a shareable download link, seconds later.**

ClipLink is a macOS menu-bar app + serverless backend. When you copy a file
(`⌘C` in Finder), ClipLink quietly uploads it and replaces the clipboard
content with a public, expiring download URL — so the next `⌘V` pastes the
link, not the file. Nothing sensitive is embedded in the app; the whole
backend runs free-tier on Cloudflare.

## Features

- **Clipboard detection** — Finder `⌘C` on one or more files triggers a share automatically (file URLs on the pasteboard).
- **Clipboard replacement** — the link is written back to the clipboard, ready to paste.
- **Menu-bar UI** — pause/resume monitoring, list your recent links (copy/revoke), open the share page, and set the backend URL.
- **Privacy blocklist** — files matching patterns like `id_rsa*`, `*.ssh/*`, `.env*` are **never** uploaded. Patterns are configurable.
- **Self-loop protection** — ClipLink ignores its own clipboard writes; also ignores pre-existing clipboard state when the app starts.
- **Clipboard safety on failure** — if the upload fails, the original clipboard content is untouched.
- **Expiring links** — server-enforced 24h lifetime (configurable), after which both the link and the stored object are gone. Expired/revoked links show a plain "Link expired / Link revoked" page.
- **Revocation** — every share gets a secret revoke token; revoke from the menu or by `DELETE` with the token. Deletion also removes the blob from storage.
- **Server-side limits, no secrets in the app** — size/rate/expiration limits live in Worker config; the app just adapts to what the server advertises.

## Repository layout

```
backend/      Cloudflare Worker (R2 + D1), D1 schema, wrangler config
macapp/       Swift package: ClipLinkCore + ClipLink (menu-bar app) + ClipLinkCLI
scripts/      make-app.sh, make-dmg.sh, make-icon.swift, test-backend.sh
docs/         design notes / PRD
```

## Backend (Cloudflare Workers)

Storage is R2 (objects) + D1 (metadata), fully on the free tier.

| Endpoint | Description |
|---|---|
| `POST /api/v1/shares` | Upload a file. Raw body, `application/octet-stream` + `X-ClipLink-Filename` header. Returns full share JSON (incl. secret `revokeToken`). |
| `GET /api/v1/shares/:token` | Share metadata JSON. |
| `GET /api/v1/shares/:token/download` | The actual bytes (`Content-Disposition: attachment`). |
| `DELETE /api/v1/shares/:token` | Revoke. Requires `X-ClipLink-Revoke-Token` header (or admin secret `X-Admin-Token`). |
| `GET /s/:token` | Human share page with download button, filename/size/expiry info. |
| `GET /api/v1/limits` | Advertised limits JSON (`maxFileBytes`, `expiryHours`, rate limits) — the app reads this before checking a file. |
| `GET /healthz` | Liveness. |

A scheduled cron (`*/10 * * * *`) purges expired objects and, after
`ROW_RETENTION_DAYS`, old metadata rows. Skipped/empty uploads get a clean
`400`; oversized a `413`; rate-limited a `429`.

### Local development (no deploy needed)

```bash
cd backend
npm install
npx wrangler d1 execute cliplink --local --file=schema.sql
npx wrangler dev --port 8787 --ip 127.0.0.1 --test-scheduled
# point the app at http://127.0.0.1:8787 (log/test: backend URL setting)
```

A second environment with tiny limits makes expiry/rate tests easy:

```bash
npx wrangler d1 execute cliplink --local --file=schema.sql --persist-to .state02
npx wrangler dev --env tiny --port 8788 --ip 127.0.0.1 --test-scheduled --persist-to .state02
# limits: 1 MB files, ~12 s expiry, 3 uploads/h
```

### Storage budget (stays inside the R2 free tier)

R2's free tier includes 10 GB of storage. The worker enforces its own
`MAX_STORAGE_GB` (default **9 GB**) so it can never be billed:

- An upload that would push total stored bytes past the budget gets a clean
  **507 `storage_full`** (with `Retry-After`) — no silent overruns.
- Every 10 minutes the cron **evicts the oldest objects** until usage is back
  under budget. Evicted links answer `410 gone` ("no longer available").
- Normal expiry cleanup happens first, so in practice the budget only kicks in
  after heavy use; and it also shrinks any *existing* buildout the moment the
  budget is lowered.

Docs (R2/D1/Workers free tiers) and `MAX_STORAGE_GB`/limits live in
`backend/wrangler.toml [vars]`.

### Deploy to Cloudflare (free tier)

```bash
cd backend
npm install

npx wrangler d1 create cliplink          # copy the database id below
npx wrangler r2 bucket create cliplink-uploads

# backend/wrangler.toml: paste the real `database_id` from the d1 create output

npx wrangler d1 execute cliplink --remote --file=schema.sql   # create tables
npx wrangler secret put ADMIN_TOKEN        # optional: lets you revoke any share via X-Admin-Token
npx wrangler deploy
```

Then point the menu-bar app's *Backend URL* to `https://cliplink-backend.<yoursubdomain>.workers.dev` (or set `PUBLIC_BASE_URL` in `wrangler.toml` [vars] if you attach a custom domain).

### Backend smoke tests

```bash
cd backend && npx wrangler dev --port 8787 --ip 127.0.0.1 --test-scheduled &
bash scripts/test-backend.sh http://127.0.0.1:8787
```

## macOS app

Build the bundle:

```bash
swift build -c release --package-path macapp
bash scripts/make-app.sh                 # → build/ClipLink.app (ad-hoc signed)
bash scripts/make-dmg.sh 0.1.0           # → build/ClipLink-0.1.0.dmg
```

Run it directly:

```bash
open build/ClipLink.app
```

On first launch the app shows a short onboarding message in the menu; enable
monitoring from the menu-bar icon (clipboard icon). All settings are stored in
`app.cliplink.ClipLink` preferences: `monitoringEnabled`, `backendURL`,
`blockedPatterns`.

### Headless CLI (for tests/CI)

```bash
swift run ClipLinkCLI types        # identify what's on the clipboard
swift run ClipLinkCLI limits --backend http://127.0.0.1:8787
swift run ClipLinkCLI upload FILE --backend http://127.0.0.1:8787
swift run ClipLinkCLI watch --backend http://127.0.0.1:8787 --once
```

## Installing the .dmg (Gatekeeper)

The shipped app is **ad-hoc signed only** (no Apple Developer ID certificate, ₹0
budget), so macOS Gatekeeper will warn on first open:

1. Open the downloaded `ClipLink-*.dmg`, drag **ClipLink** to **Applications**.
2. First launch: right-click the app → **Open** → **Open** (bypasses the warning for unsigned/ad-hoc apps).
   Or accept it in *System Settings → Privacy & Security* ("Open Anyway").
3. Binaries are plain (ad-hoc) Swift; you can rebuild from source in this repo and re-sign yourself.

## Privacy model summary

- Uploads are anonymous. No accounts, no tracking.
- The `install id` heuristic **only** feeds rate limiting, never stored as identity, never exposed via any public endpoint.
- Every share row has `revoke_token` (private, returned once to the uploader only).
- Blocklist matches the *filename before upload* — private-key-shaped files never leave the machine.
- Every link expires; the cron deletes R2 objects; nothing server-side is retained beyond `ROW_RETENTION_DAYS` past expiry.

## License

MIT — see `LICENSE` shipped in the DMG and in the repo root.
