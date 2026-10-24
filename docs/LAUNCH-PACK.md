# Launch pack — getting ClipLink visible, free

Everything in here is **zero-cost**. Copy-paste-ready drafts are included.
Order matters — follow the phases. Schedule suggestions use UTC; the sweet
spot for tech audiences is Tue–Thu, 14:00–17:00 UTC (morning Europe, business
hours US).

---

## Phase 0 — prerequisites (all done ✅)

- [x] Landing site live with OG image, canonical, sitemap, robots.txt, JSON-LD
- [x] GitHub repo: description, homepage link, 13 search topics, MIT licence
- [x] Releases auto-built by CI; app installable in 2 clicks
- [x] Discussions enabled; pinned "community roadmap" issue live (gh)
- [x] IndexNow key hosted on the site; URLs submitted directly to
      api.indexnow.org (HTTP 202) — Bing/Yandex/Seznam begin crawling
- [ ] **You:** upload the social preview image — repo → ⚙ Settings → Social
  preview → drag `og.png` (from the website repo) into both repos.
- [ ] **You:** pin `cliplink` + `cliplink-website` on your profile (no API).
- [ ] **You (optional):** record a 30-second demo GIF using
  [`DEMO-SCRIPT.md`](DEMO-SCRIPT.md). This asset *doubles* click-through.

## Phase 1 — search engines (quiet, compound interest)

1. **Google Search Console** (free): verify `sayyidsajad.github.io/cliplink-website/`
   — pick the *URL-prefix* property, verify by HTML file (there is no
   GitHub-pages DNS control): create `google<hash>.html` per their prompt and
   commit it here. Then Sitemaps → submit `https://sayyidsajad.github.io/cliplink-website/sitemap.xml`.
2. **Bing Webmaster Tools** (free): import the GSC property; it also feeds
   DuckDuckGo in 2026.
3. Expect indexing within ~3–7 days of GSC submission.

## Phase 2 — GitHub-native discoverability (free, high-intent traffic)

- Topics are set (macos, file-sharing, expiring-links, …) — you appear in
  github.com/topics/* pages already.
- **Pin the repo** on your profile (Profile → Customize your pins).
- **Enable Discussions** so early users can post (Settings → Discussions), and
  consider `⭐ Sponsor` link already present.
- Open a short issue titled "Poll: what should ClipLink support next?" — gives
  visitors an easy first interaction.
- **awesome-list PRs** (draft text below): `awesome-macos`, `awesome-macos-apps`,
  `awesome-swift`, `awesome-privacy`. Search for them on GitHub, open ONE PR
  each with a single-line addition in alphabetical order.

## Phase 3 — the day-one posts (the real spike)

**Show HN** (news.ycombinator.com → the Post button). Launch Tip: post Tue/Wed
14:00–16:00 UTC. Replying to every comment early matters more than the post
itself.

> **Title:** Show HN: ClipLink – copy a file in Finder, paste a self-destructing link
>
> **Body (use your own words; make it story-first, short):**
> Story: I share screenshots/downloads constantly and hated upload-forms +
> dead links. ClipLink watches the clipboard: copy a file in Finder, and the
> menu-bar app uploads it and puts an expiring download link on your
> clipboard — paste anywhere, works in every browser without an account.
> Links live 24 h, then the file and metadata are deleted; there is a revoke
> token per share. Everything is MIT, the backend is ~2 files of JS on
> Cloudflare Workers (D1) with Supabase Storage, and the app is Swift. No
> accounts, no tracking, no analytics — the whole system fits in ~1000 lines.
> Website: https://sayyidsajad.github.io/cliplink-website/ ·
> Source: https://github.com/sayyidsajad/cliplink
> Ask: try it, break it, tell me what's missing.

**Product Hunt** (producthunt.com → Post a Product). Free; schedule via the
built-in scheduler for 00:01 PT *after* making a maker profile. Do not stress
PH anymore for traffic — use it for the permanent directory backlink.

> **Tagline (≤60 chars):** Copy files in Finder → self-destructing share links
> **Description:** ClipLink is a free, open-source macOS menu-bar app that
> turns Finder ⌘C into a private, expiring download link — no accounts, no
> trackers, links auto-delete in 24 h, MIT, backend is auditable in minutes.
> **First comment:** honest story + how privacy works + link to the legal docs
> ( people trust this ) + roadmap request.

**Reddit** — one post per community, tone = "asking for feedback", never
marketing-speak. Best-fit subs: `r/macapps`, `r/apple`, `r/opensource`,
`r/SideProject`. Paste-wait-then-next:

> **Title:** I built ClipLink — copy a file in Finder, get a self-destructing
> download link (free & open source)
> **Body:** what it does in 2 lines · why (frustration story) · privacy model
> (deleted in 24 h, no accounts, no scanning) · MIT GitHub link · demo GIF ·
> "Looking for feedback, especially edge cases & macOS folks."

Unwritten rules that actually matter: 1 post per sub per week, reply to
everyone for the first ~8 h, disclose that you are the maker.

## Phase 4 — directories & listings (slow burn, do once)

| Channel | Direct link (free) | Action |
|---|---|---|
| AlternativeTo | alternative.me → "Add Software" | search ClipLink first; if absent create entry "ClipLink — copy files → self-destructing share links" and list as alternative to WeTransfer / Dropmark / CloudApp |
| MacUpdate | macupdate.com → submit (footer → "Submit Software") | attach og.png + demo GIF |
| Softpedia | softpedia.com → "Submit a free app" | mark freeware; MIT |
| Slant.co | "Alternatives to WeTransfer" question | short answer, first line = one-sentence value, then link |
| BetaList / Indie Hackers | poststory + milestone post | optional; pick one |
| X / Mastodon / LinkedIn | thread: 1 problem → 1 demo GIF → 1 link → 1 honesty note ("no trackers by design") | pin the thread |

## Phase 5 — evergreen compounding

- Release notes post per version (releases page); each release GitHub pushes
  to follower feeds.
- Record the demo clip using [`DEMO-SCRIPT.md`](DEMO-SCRIPT.md) — GIF in
  README + post assets.
- "How it works" curiosity content: `docs/DESIGN.md` already exists; consider
  a 1-page "the two-file backend explained" post linked from the website later.
- Keep answering issues/PRs publicly; activity itself is indexed content.
- Self-hosted backend mature enough → PR to awesome-selfhosted.

---

## What not to do (protects the reputation you are building)

- No posting the same text in multiple places the same hour (looks spammy,
  and some communities auto-flag).
- No fake reddit/vote rings — communities detect and ban.
- Do not rename URLs or move the site after indexing; canonical is set.
- Never remove the legal docs to "look cleaner" — the safe-harbour paperwork
  is also trust content.

## Honest expectations

Free + no-budget means: HN spike (if it hits) ~1–2k visits, PH ~hundreds,
Reddit hundreds-to-low-thousands, search compounds only after ~1–2 months,
directories after weeks. Total addressable realistic metric after 3 months:
1k–10k page views, some hundreds of DMGs. Measure via GitHub stars/Downloads
badge and Search Console — the site stays tracker-free by design.
