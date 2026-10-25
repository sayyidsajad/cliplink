# Legal & Operations Runbook

Practical procedures for operating the hosted ClipLink service responsibly.
This is the maintainer's playbook — not legal advice.

Related reading: website [Terms](https://sayyidsajad.github.io/cliplink-website/terms.html) ·
[Privacy Policy](https://sayyidsajad.github.io/cliplink-website/privacy.html) ·
[SECURITY.md](../SECURITY.md) · [LICENSE](../LICENSE) (MIT).

---

## 0. The core legal posture

- The **code** is MIT-licensed: users, not the operator, bear most software risk.
  The LICENSE states **no warranty** and caps liability — keep those clauses intact.
- The **hosted service** (`api.cliplink.workers.dev`) is the real exposure: the
  operator is an Indian individual acting as an *intermediary* under the
  [IT Act, 2000](https://www.indiacode.nic.in/) and the **IT Rules, 2021**, and as a
  *data controller* in spirit under the **DPDP Act, 2023**.
- Intermediary safe-harbour (§79 IT Act) requires the due-diligence duties the
  Terms and this runbook implement: an acceptable-use policy, a published
  grievance channel, and takedown response. **These documents are the conditions
  of the safe harbour — do not remove them.**
- **No disclaimer eliminates all risk.** Residual risk is logged in §7.

## 1. Abuse / takedown handling ("reactive moderation")

ClipLink deliberately does **not** scan or pre-screen uploads. Deletion-only,
reactive handling is the model. When a report arrives (via the
[abuse-report issue template](https://github.com/sayyidsajad/cliplink/issues/new?template=abuse-report.md)
or direct e-mail once available):

1. **Verify the token is live.**
   ```bash
   curl -s "https://api.cliplink.workers.dev/s/<TOKEN>" | head -40
   ```
2. **Revoke immediately** (only you have the admin token):
   ```bash
   curl -X DELETE "https://api.cliplink.workers.dev/api/v1/shares/<TOKEN>" \
        -H "Authorization: Bearer $ADMIN_TOKEN"
   ```
   Revocation is instant: the share page flips to "revoked", the signed-URL
   path refuses revoked rows, and the blob is deleted server-side.
3. **Log the decision** in a private local file: date, token (after revocation
   the row self-purges within retention, so capture it first: token, filename,
   size, report text). Keep for the retention you prefer; never keep file
   contents.
4. **Respond to the reporter** with the action taken and date.
5. **CSAM / credible crime reports:** revoke, do **not** view further, keep a
   single-record log (date, token, action), and evaluate notification duties
   (e.g. the National Cyber Crime portal / local police). Time is of the
   essence — escalate the same day.

### Timing standard (published in the Terms)
- Acknowledge: ≤ **24 h**
- Takedown/status update: ≤ **72 h**

## 2. Copyright & DMCA-style notices

A valid notice has six elements (§512(c)(3) DMCA, mirrored in the issue
template): work identification, URL/token of the material, reporter contact,
good-faith statement, accuracy statement, signature. If any required element is
missing, reply once requesting the missing piece; do not take action on
incomplete notices, but note them. On a complete valid notice: revoke per §1,
record both the notice and your response, and consider the "repeat infringer"
stance documented in the Terms (removal on each valid notice; the built-in
rate-limit and 7-day retention already suppress large-scale repeaters).
Counter-notices: a designated DMCA agent registration is being filed (walkthrough: [`docs/DMCA-REGISTRATION.md`](DMCA-REGISTRATION.md)); until the filing lands in the public directory, treat the notice procedure as good-faith compliance, not statutory DMCA process.

## 3. India-specific duties

| Duty | Source | What we do |
|---|---|---|
| Grievance officer published with response timelines | IT Rules 2021, rule 3(2)/4 | Named in Terms §11; GitHub reports channel; 24 h/72 h targets |
| Takedown for unlawful content when tasked by valid order/appropriate government | s.79(3)(b), s.69A IT Act | Revoke immediately per §1; preserve minimal logs if order requires |
| Retain specific data on direction | s.69A / direction | D1 rows exist for ≤7 days post-expiry unless an order requires otherwise; by default we purge |
| CERT-In cyber-incident reporting when applicable | CERT-In Directions 2022 (6-hour window for specified incidents) | If an incident necessitates it: report to `<incident@cert-in.org.in>` with prescribed fields; do not wait to also notify users |
| Children's data | DPDP Act 2023 s.9 | Service is 18+ only (consent checkbox in app + Terms); no child data knowingly processed |
| Purpose limitation & erasure | DPDP Act 2023 | Privacy Policy §6 grants access/correction/erasure; implementable because rows are anonymous and token-linked |

## 4. Service kill-switch (containment playbook)

If the service is being abused at scale and immediate containment is needed:

1. **Dry out new uploads** — set `wrangler.toml` `MAX_FILE_MB = 0` (or
   `RATE_LIMIT_UPLOADS = 0` to accept zero uploads) and redeploy:
   ```bash
   cd backend && npx wrangler deploy
   ```
   An upload limit of 0 makes every share request fail fast while existing
   links keep expiring normally.
2. **Full stop** (nuclear): disable the worker route, then delete the
   infrastructure when calm returns.
   ```bash
   npx wrangler delete            # removes the worker
   ```
   D1 metadata remains; BYO files are already in users' own Drives (a parked
   link expires point-in-time regardless); the legacy Supabase bucket expires
   out after its ≤ 7-day row retention.
3. **Rotating the origin** afterwards: re-deploy with feature flags off, raise
   limits slowly, watch the logs.

## 5. Record-keeping

Maintain (locally, never committed): a dated log of every abuse report and
takedown (token prefix, decision, block rationale), a list of legal requests
received from authorities, and versions of the Terms/Privacy you served on each
date (a `git log` of this website repo already supplies this).

## 6. The no-guarantee clause (put this in your head, not just in a doc)

An EULA, ToS, or licence reduces exposure; it doesn't erase it. Criminal law,
consumer law, and human-rights obligations cannot be disclaimed away, and a
court applies them regardless of what a website says. The runbook exists to
demonstrate ongoing good-faith operator conduct — which is the strongest
practical protection available.

## 7. Residual risks & operator action items

**Done (2026-10-24):**
- [x] Public report mailbox published: `sayyidsajada4s@gmail.com`
      (Terms §4/§11, Privacy §10, SECURITY.md, issue template).
- [x] DMCA registration prepared (field-by-field walkthrough:
      [`DMCA-REGISTRATION.md`](DMCA-REGISTRATION.md)) — filing itself requires
      the maintainer's Login.gov sign-in.
- [x] Governing-law venue resolved: **Kochi, Kerala, India** named in Terms §10
      (maintainer's confirmed city of residence).
- [x] Lawyer-review pack prepared: [`LAWYER-BRIEF.md`](LAWYER-BRIEF.md)
      (10-point question list; sign-off template at the end).

**Maintainer actions remaining:**
- [ ] Verify `sayyidsajada4s@gmail.com` actually receives mail and you can
      respond within 24 h (it is now the published grievance channel).
- [ ] File the DMCA agent registration (10 min, $6; see walkthrough).
- [ ] Get a one-hour lawyer review using `LAWYER-BRIEF.md` before heavy
      publicity.
- [ ] Consider incorporation (One Person Company / LLP) and/or tech-liability
      insurance if the service grows beyond a hobby footprint.

**Structural (accepted, mitigated) risks:**
- Anonymous uploads means malware/phishing can be shared by bad actors between
  takedown ⇒ mitigated by: rate limits, 24 h expiry, instant
  revocation, reactive moderation per this runbook. **Since v0.4 the file bytes
  live in the uploader's own Google Drive** — with a healthy abuse report the
  operator deletes the *object* immediately; being in the user's Drive also
  puts content moderation largely behind Google's own abuse stack. Code
  execution of arbitrary payloads is still facilitated (the risk that remains
  is *linking*, not hosting); a Cloudflare Turnstile upload barrier is the
  planned next mitigation if volume justifies it. The residual
  branding/reputational risk is the largest and cannot be fully engineered away
  under an anonymous model.
- No continuous monitoring ⇒ lawful content can slip through; mitigated by
  fast takedown and documented timings.
- Personal-liability model (sole individual, no company) ⇒ Terms cap damages
  but do not immunise against core fraud/misconduct; incorporation would improve this.
- Global reach vs. single-country operator ⇒ Terms attempt mutual consumer
  carve-outs for EU/UK consumers; not perfect.

**Footer / 2026-10-25:** since this date the hosted instance is **BYO-only**
(`STORAGE_PROVIDER="drive"`); legacy Supabase rows (v0.3, ≤ 12 shares, all
created 2026-10-18..25) expire within their 24 h lifetime. The Supabase
project (`mqqkubgcourkwbkaetfv`) is to be deleted no later than **2026-11-02**,
after which its access token must be revoked in the Supabase dashboard and the
`SUPABASE_URL` / `SUPABASE_SERVICE_KEY` Worker secrets removed.
