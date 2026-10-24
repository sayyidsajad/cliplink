# DMCA Designated Agent — registration walkthrough

Goal: put ClipLink's hosted service (`api.cliplink.workers.dev`) in the
[U.S. Copyright Office DMCA Designated Agent Directory](https://dmca.copyright.gov/),
which strengthens the safe-harbour position under 17 U.S.C. §512(c) for U.S.
takedown notices.

**Status: ⏳ ready to file — the only remaining steps are identity-verified and
can only be done by the maintainer in person (Login.gov requires it).**
Everything else is prepared below — the registration takes ~10 minutes.

## Why this matters (and why it is optional but wise)

- Without a registered agent, a valid DMCA complaint that names ClipLink's
  e-mail box can still be answered on good-faith grounds (and Indian law only
  needs the grievance channel we already run) — but §512(c) safe harbour in
  U.S. litigation formally requires a *registered* agent.
- Registration is cheap ($6/service-provider record) and public, modestly
  increasing spam to the listed mailbox — hence the dedicated address.

## Information to enter in the form (copy-paste ready)

| Form field | Value |
|---|---|
| Service provider name | ClipLink |
| Service provider alternate names | `api.cliplink.workers.dev` |
| Service provider website | https://github.com/sayyidsajad/cliplink |
| Registrant type | Sole operator / individual proprietor |
| Agent name | Sayyid Sajad |
| Agent contact e-mail | `sayyidsajada4s@gmail.com` |
| Agent phone | (optional — enter a number you accept to be public, or leave blank if the form allows) |
| Agent address | enter your real postal address (this becomes PUBLIC — see privacy note) |
| Third-party agent? | No (the agent is the operator themselves) |
| Categories / domains to cover | `api.cliplink.workers.dev` (hosted service); `sayyidsajad.github.io` (website pages) |

⚠ **Privacy note:** everything in the filing becomes a **public directory
entry**, including the postal address. If your national privacy preference is
"no", you may substitute `GENERAL/MINIMAL` contact scheme only where US rules
allow (the current form requires an address; some registrants use a
registered-agent service or PO box). Your call.

> **Fee:** currently a one-time $6 per service-provider designation (paid in
> the portal). Renewal is required if details change; the designation must be
> "amended" when the agent or address changes.

## Steps

1. [ ] Create/verify a [**Login.gov**](https://login.gov) account (needs a real
   e-mail and, for IAL1, just password+2FA; no US ID needed for this filing).
2. [ ] Go to <https://dmca.copyright.gov/dmca/login.html> → **Sign in with Login.gov**.
3. [ ] "Register a Service Provider" → fill the table above (skip phone if
   unsure).
4. [ ] Pay the fee (accepts cards; the $6 is per designation).
5. [ ] Finish submission → the agent appears in the public
   [DMCA Directory](https://dmca.copyright.gov/dmca-directory/) within a short
   processing time.
6. [ ] Come back here and tick the box below, then update `terms.html`:

```markdown
Status: ✅ registered on <DATE>, entry
https://dmca.copyright.gov/dmca-directory/?id=<YOUR-ID>
```

7. [ ] Update the website `terms.html` §4 — replace the "pending formal
   registration" wording with the directory link.
8. [ ] Add the registration to your calendar for renewal/amendment triggers
   (address, agent, or service-provider details change).

## After registration — keep references in sync

- Website `terms.html` §4 — replace the "pending" wording.
- `docs/LEGAL-RUNBOOK.md` §2 — update the "not currently registered" note.
- `SECURITY.md` — the notice/receiving channel stays
  `sayyidsajada4s@gmail.com`.
