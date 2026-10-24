# ClipLink

**Copy a file in Finder → paste a shareable download link, seconds later.**

ClipLink is a macOS menu-bar app + serverless backend. When you copy a file
(`⌘C` in Finder), ClipLink quietly uploads it and replaces the clipboard
content with a public, expiring download URL — so the next `⌘V` pastes the
link, not the file. Nothing sensitive is embedded in the app; the whole
backend runs free-tier on Cloudflare + Supabase with zero payment cards.

The shared hosted instance runs at **`https://api.cliplink.workers.dev`**
(preconfigured in the released app; **download site: <https://sayyidsajad.github.io/cliplink-website/>**).
Everything can also be self-hosted — see *Deploy* below.

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
- **Cardless storage** — blobs live in Supabase Storage (free, no card required); metadata in Cloudflare D1. A storage budget keeps everything inside the free tiers.

## Repository layout

```
backend/      Cloudflare Worker (Supabase Storage + D1), D1 schema, wrangler config
macapp/       Swift package: ClipLinkCore + ClipLink (menu-bar app) + ClipLinkCLI
scripts/      make-app.sh, make-dmg.sh, make-icon.swift, test-backend.sh
docs/         design notes / PRD
```

## Backend (Cloudflare Workers)

Blobs live in **Supabase Storage** (cardless free tier, private bucket + short-lived
signed URLs proxied through the Worker); metadata in **Cloudflare D1**. Both free,
no payment card required anywhere.

| Endpoint | Description |
|---|---|
| `POST /api/v1/shares` | Upload a file. Raw body, `application/octet-stream` + `X-ClipLink-Filename` header. Returns full share JSON (incl. secret `revokeToken`). |
| `GET /api/v1/shares/:token` | Share metadata JSON. |
| `GET /api/v1/shares/:token/download` | The actual bytes (`Content-Disposition: attachment`). |
| `DELETE /api/v1/shares/:token` | Revoke. Requires `X-ClipLink-Revoke-Token` header (or admin secret `X-Admin-Token`). |
| `GET /s/:token` | Human share page with download button, filename/size/expiry info. |
| `GET /api/v1/limits` | Advertised limits JSON (`maxFileBytes`, `expiryHours`, rate limits) — the app reads this before checking a file. |
| `GET /healthz` | Liveness. |

A scheduled cron (`*/10 * * * *`) purges expired objects, evicts the oldest ones
when the storage budget is exceeded, and pings Supabase so the free project is
never paused. Skipped/empty uploads get a clean `400`; oversized a `413`;
rate-limited a `429`; over-budget a `507`.

### Local development (no deploy needed)

```bash
cd backend
npm install
npx wrangler d1 execute cliplink --local --file=schema.sql
npx wrangler dev --port 8787 --ip 127.0.0.1 --test-scheduled
# point the app at http://127.0.0.1:8787 (log/test: backend URL setting)
```

Local dev also needs the Supabase blob credentials in `backend/.dev.vars`
(gitignored):

```
SUPABASE_URL="https://<project-ref>.supabase.co"
SUPABASE_SERVICE_KEY="<service_role key>"
STORAGE_BUCKET="cliplink-dev"
```

Create the bucket once via the Storage API (service key auth):
`POST {SUPABASE_URL}/storage/v1/bucket {"name":"cliplink-dev","public":false}`.

A second environment with tiny limits makes expiry/rate tests easy:

```bash
npx wrangler d1 execute cliplink --local --file=schema.sql --persist-to .state02
npx wrangler dev --env tiny --port 8788 --ip 127.0.0.1 --test-scheduled --persist-to .state02
# limits: 1 MB files, ~12 s expiry, 3 uploads/h
```

### Storage budget (stays inside the free tiers)

Supabase Storage's free tier is 1 GB / month. The worker enforces its own
`MAX_STORAGE_GB` (default **0.9 GB**) so it can never be billed:

- An upload that would push total stored bytes past the budget gets a clean
  **507 `storage_full`** (with `Retry-After`) — no silent overruns.
- Every 10 minutes the cron **evicts the oldest objects** until usage is back
  under budget. Evicted links answer `410 gone` ("no longer available").
- Normal expiry cleanup happens first, so in practice the budget only kicks in
  after heavy use; and it also shrinks any *existing* buildout the moment the
  budget is lowered.

All tunables (`MAX_FILE_MB`, expiry, rate limits, `MAX_STORAGE_GB`) live in
`backend/wrangler.toml [vars]`.

### Deploy to Cloudflare + Supabase (both free, no card)

*Cloudflare side (metadata):*

```bash
cd backend
npm install
npx wrangler d1 create cliplink        # paste the printed database_id into wrangler.toml
npx wrangler d1 execute cliplink --remote --file=schema.sql
```

*Supabase side (blobs):*

1. supabase.com → new project (free plan; region e.g. ap-south-1).
2. Storage → create a **private** bucket named `cliplink-files`.
   (Free tier caps a single object at 50 MB — hence `MAX_FILE_MB="49"`.)
3. Settings → API → copy **Project URL** and **service_role key**.

*Wire them together:*

```bash
npx wrangler deploy                                          # first deploy
printf 'https://<ref>.supabase.co'  | npx wrangler secret put SUPABASE_URL
printf '<service_role key>'         | npx wrangler secret put SUPABASE_SERVICE_KEY
npx wrangler secret put ADMIN_TOKEN                           # optional: admin revoke via X-Admin-Token
npx wrangler deploy                                          # picks up secrets
```

The Worker serves at `https://<worker-name>.<subdomain>.workers.dev` — set that
as the menu-bar app's *Backend URL* (or `PUBLIC_BASE_URL` with a custom domain).

*Using the Supabase CLI instead? (`supabase projects create …`) needs a
**plain full-access** access token from Account → Access tokens — scoped
tokens get Forbidden on project creation.*

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

## Legal & compliance

Documents that govern the **hosted service** (the code is MIT; the hosted
`api.cliplink.workers.dev` endpoint additionally runs under these):

| Document | Location |
|---|---|
| Terms of Use (includes DMCA + IT-Rules grievance process) | <https://sayyidsajad.github.io/cliplink-website/terms.html> |
| Privacy Policy (data-minimal, DPDP-aware) | <https://sayyidsajad.github.io/cliplink-website/privacy.html> |
| Security policy & vulnerability reporting | [`SECURITY.md`](SECURITY.md) |
| Legal & operations runbook (takedowns, CERT-In, kill switch, residual-risk log) | [`docs/LEGAL-RUNBOOK.md`](docs/LEGAL-RUNBOOK.md) |
| DMCA agent registration walkthrough | [`docs/DMCA-REGISTRATION.md`](docs/DMCA-REGISTRATION.md) |
| Lawyer-review brief (10-point question list) | [`docs/LAWYER-BRIEF.md`](docs/LAWYER-BRIEF.md) |
| Abuse reports | e-mail **sayyidsajada4s@gmail.com** or the [abuse template](https://github.com/sayyidsajad/cliplink/issues/new?template=abuse-report.md) |

Surface points for these documents:

- Website nav + footer (every page);
- Share/error pages footer (`backend/src/page.js`);
- App onboarding — consent checkbox **gates Start Monitoring** (v0.3.2+).

**Transparent limitations:** these documents implement a good-faith compliance
programme (India IT Rules 2021, DPDPA 2023, DMCA-style notice handling,
EU-consumer-law carve-outs). They **do not provide immunity** — see
`docs/LEGAL-RUNBOOK.md` §6–7 for the honest residual-risk list.

## License

MIT — see `LICENSE` shipped in the DMG and in the repo root. The MIT licence
covers the source code; use of the hosted service is subject to the Terms above.
