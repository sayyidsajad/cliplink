# ClipLink

**Copy a file in Finder → paste a shareable download link, seconds later.**

ClipLink is a macOS menu-bar app + serverless backend. When you copy a file
(`⌘C` in Finder), ClipLink quietly uploads it and replaces the clipboard
content with a public, expiring download URL — so the next `⌘V` pastes the
link, not the file. Nothing sensitive is embedded in the app; the whole
backend runs **free** on Cloudflare, and your **files live in your own
Google Drive** (BYO storage), so file-bytes operating cost is zero.

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
- **BYO storage (v0.4+)** — files are uploaded into the **uploader's own Google Drive**; the backend stores only metadata + an AES-GCM-sealed OAuth refresh token (see [BYO storage](#byo-storage-v04) below).
- **ClipLink Pro (v0.5+)** — one-time purchase unlock (no subscription): 🔒 **password-protected links**, **custom link expiry** (1 week / 30 days), and **per-link QR codes** (see [ClipLink Pro](#cliplink-pro-v05) below).

## Repository layout

```
backend/      Cloudflare Worker (Google Drive + D1), D1 schema, wrangler config
macapp/       Swift package: ClipLinkCore + ClipLink (menu-bar app) + ClipLinkCLI
scripts/      make-app.sh, make-dmg.sh, make-icon.swift, test-backend.sh
docs/         design notes / PRD
```

## Backend (Cloudflare Workers)

Metadata lives in **Cloudflare D1**; file bytes stream **straight into the
uploader's Google Drive** (resumable 8 MiB chunks; Range requests proxied back
on download). The Worker never stores a byte of file content.

| Endpoint | Description |
|---|---|
| `POST /api/v1/shares` | Upload a file. Raw body, `application/octet-stream` + `X-ClipLink-Filename` header. Returns full share JSON (incl. secret `revokeToken`). |
| `GET /api/v1/shares/:token` | Share metadata JSON. |
| `GET /api/v1/shares/:token/download` | The actual bytes (`Content-Disposition: attachment`). |
| `DELETE /api/v1/shares/:token` | Revoke. Requires `X-ClipLink-Revoke-Token` header (or admin secret `X-Admin-Token`). |
| `GET /s/:token` | Human share page with download button, filename/size/expiry info. |
| `GET /api/v1/limits` | Advertised limits JSON (`maxFileBytes`, `expiryHours`, rate limits, `storageProvider`) — the app reads this before checking a file. |
| `GET /healthz` | Liveness. |
| `GET /api/v1/providers/drive/authorize` | Start the BYO connect flow (`{authorizeUrl, state}`). |
| `GET /api/v1/providers/drive/poll?state=` | App polls until the browser consent completes. |
| `GET /oauth/drive/callback` | Google OAuth redirect target (opens-to-close HTML page). |

A scheduled cron (`*/10 * * * *`) deletes expired objects (in the user's Drive
for BYO shares; in Supabase for legacy rows), evicts the oldest legacy objects
when the storage budget is exceeded, and retries object deletion for revoked
shares. Skipped/empty uploads get a clean `400`; oversized a `413`;
rate-limited a `429`; over-budget a `507` (legacy storage only).

### Local development (no deploy needed)

```bash
cd backend
npm install
npx wrangler d1 execute cliplink --local --file=migrate-byo.sql
npx wrangler dev --port 8787 --ip 127.0.0.1 --test-scheduled
# point the app at http://127.0.0.1:8787 (log/test: backend URL setting)
```

Local dev runs the **mock provider** — a D1-backed test blob store, no Google
account needed. Add to `.dev.vars` (gitignored):

```
STORAGE_PROVIDER="mock"
MOCK_PROVIDER="1"
TOKEN_SECRET="dev-token-secret-do-not-use-in-prod"
```

Guest shares (uploads without a connected Drive) are only possible with
`MOCK_PROVIDER=1`, never in production. To test the *real* Drive path locally,
set `STORAGE_PROVIDER="drive"` plus `DRIVE_CLIENT_ID`/`DRIVE_CLIENT_SECRET`
and add `http://127.0.0.1:8787/oauth/drive/callback` as an authorised redirect
URI on the OAuth client (dev-only; remove it after testing).

A second environment with tiny limits makes expiry/rate tests easy:

```bash
npx wrangler d1 execute cliplink --local --file=migrate-byo.sql --persist-to .state02
npx wrangler dev --env tiny --port 8788 --ip 127.0.0.1 --test-scheduled --persist-to .state02
# limits: 1 MB files, ~12 s expiry, 3 uploads/h
```

### Legacy storage budget (Supabase rows only)

v0.3-era shares keep their bytes in Supabase Storage. The worker enforces a
`MAX_STORAGE_GB` ceiling (default **0.9 GB**) so the free tier can never be
billed while they live out their ≤ 24 h lifetimes:

- An upload that would push total stored bytes past the budget gets a clean
  **507 `storage_full`** (with `Retry-After`) — no silent overruns.
- Every 10 minutes the cron **evicts the oldest legacy objects** until usage
  is back under budget. Evicted links answer `410 gone`.
- BYO (Drive) rows are excluded from the budget — they hold no bytes on our
  side. Once every legacy row has expired, the Supabase project is deleted
  entirely and even this budget stops mattering.

All tunables (`MAX_FILE_MB`, expiry, rate limits, `MAX_STORAGE_GB`) live in
`backend/wrangler.toml [vars]`.

### Deploy (Cloudflare only; the storage is *your users'* Drive)

1. `npx wrangler d1 create cliplink` — paste the printed database ID into
   `wrangler.toml`, then `npx wrangler d1 execute cliplink --remote --file=schema.sql`.
2. Create a Google OAuth client (Web application) with redirect URI
   `https://<your-worker>/oauth/drive/callback`, enable the **Google Drive
   API** on that project, add `https://www.googleapis.com/auth/drive.file`
   to the consent screen's **Data Access**, and publish the consent screen
   (unverified production = tokens don't expire weekly).
3. Wire secrets + deploy:

```bash
npx wrangler secret put DRIVE_CLIENT_ID      # OAuth client id
npx wrangler secret put DRIVE_CLIENT_SECRET  # OAuth client secret
npx wrangler secret put TOKEN_SECRET         # openssl rand -base64 48 — keys AES-GCM sealing; back it up, never rotate casually
npx wrangler secret put ADMIN_TOKEN          # optional: admin revoke via X-Admin-Token
npx wrangler deploy
```

4. Existing installs upgrading from ≤0.3 need the idempotent migration:
   `npx wrangler d1 execute cliplink --remote --file=migrate-byo.sql --yes`.

The Worker serves at `https://<worker-name>.<subdomain>.workers.dev` — set that
as the menu-bar app's *Backend URL* (or `PUBLIC_BASE_URL` with a custom domain).

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

On first launch the app walks through onboarding: the legal-consent checkbox
and (when the backend runs BYO storage) a **Connect Google Drive** step, both
of which gate **Start Monitoring**. All settings are stored in
`app.cliplink.ClipLink` preferences: `monitoringEnabled`, `backendURL`,
`blockedPatterns`, `driveConnectionID`, `driveEmail`.

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

## BYO storage (v0.4+)

Ownership of the actual files moved to the **user**: uploads land in the
uploader's own **Google Drive**, and the ClipLink backend (Cloudflare Worker +
D1) keeps only share metadata plus an **AES-GCM-sealed** OAuth refresh token —
zero file bytes ever touch the operator's infrastructure.

- Onboarding has a **Connect Google Drive** step (PKCE OAuth; connection is
  bound to the app's install id); Start Monitoring is gated on it whenever the
  backend advertises `storageProvider: "drive"`.
- Scope is `drive.file` — ClipLink can only ever see the files it created.
- Downloads and short links work exactly as before: the Worker proxies the
  bytes, enforces expiry/revocation, and the expiry cron deletes the copy in
  **the user's** Drive — even when their Mac is offline.
- Legacy shares (v0.3-era, Supabase-backed) keep working until they expire;
  after that the Supabase project is retired and storage cost drops to zero.

**Transparent limitations:** these documents implement a good-faith compliance
programme (India IT Rules 2021, DPDPA 2023, DMCA-style notice handling,
EU-consumer-law carve-outs). They **do not provide immunity** — see
`docs/LEGAL-RUNBOOK.md` §6–7 for the honest residual-risk list.

## ClipLink Pro (v0.5+)

One-time payment, **no subscription**. Everything ships in the free core; Pro
unlocks three conveniences enforced **server-side** (a non-licensed client is
rejected with `403 pro_required`):

| Feature | How it works |
| --- | --- |
| 🔒 Password-protected links | Share page asks for a password; the backend stores only a **PBKDF2-SHA-256 hash** (plaintext is never persisted). Unlock issues a 15-minute HMAC grant (HttpOnly cookie / `X-ClipLink-Access`). |
| Custom link expiry | `X-ClipLink-Expiry-Hours` per upload — up to **30 days** (default stays 24 h). |
| QR codes | Generated **client-side** via CoreImage → "Copy QR Code (PNG)" per link; the backend never sees them. |

**License keys.** A key (`CLPRO-XXXX-XXXX-XXXX-XXXX`) is an HMAC payload minted
from the operator's server-side seed; the Worker verifies it offline — nothing
needs to be stored to prove a key. Keys are bound to at most **5 installs**
(a non-reversible key id + install list live in D1; never the raw key). The app
activates via Preferences → *Activate* (`POST /api/v1/license/verify`).

Mint a key for a new sale:

```sh
node scripts/gen-pro-license.js <serial>   # serial = your sale record, keys are deterministic per serial
```

API surface: `POST /s/:token/access` (form unlock), `POST
/api/v1/shares/:token/unlock` (JSON unlock → `accessToken` grant), `POST
/api/v1/license/verify`. See `backend/migrate-pro.sql` for the D1 additions.

## License

MIT — see `LICENSE` shipped in the DMG and in the repo root. The MIT licence
covers the source code; use of the hosted service is subject to the Terms above.
