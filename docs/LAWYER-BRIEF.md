# Lawyer review brief — ClipLink

A one-to-two-hour briefing a licensed lawyer can scan and answer in one sitting.
Goal: professional verdict on the legal documents shipped with ClipLink, plus
sign-off or punch-list.

## Document inventory for review (all in-repo / one site)

| # | Document | Where |
|---|---|---|
| 1 | MIT License (software, code only) | `LICENSE` |
| 2 | Terms of Use (hosted service + software use) | website `terms.html` |
| 3 | Privacy Policy | website `privacy.html` |
| 4 | Security policy | `SECURITY.md` |
| 5 | Abuse-report template (grievance intake form) | `.github/ISSUE_TEMPLATE/abuse-report.md` |
| 6 | Legal & Operations Runbook | `docs/LEGAL-RUNBOOK.md` |
| 7 | DMCA registration walkthrough (pending filing) | `docs/DMCA-REGISTRATION.md` |

## Operator profile (context for the lawyer)

- Sole individual, resident in India, unpaid (free service; no revenue yet).
- Backend: Cloudflare Worker exposing an anonymous, expiring file-upload API
  (24 h default); Cloudflare's global edge network; storage at Supabase
  (private buckets);
  no accounts, no cookies, no analytics. App: macOS, MIT.
- Reactive-only moderation: no proactive scanning, ever.
- Terms cap aggregate liability at ₹10,000; 18+ usage rule; India-law
  governing law with venue at operator's residence; EU/UK consumer rights
  carve-outs; IT Rules 2021 grievance/officer response targets; DPDP-2023
  rights section.

## Questions I want the lawyer to answer explicitly

1. **India validity of the liability cap** — does a services/consumer cap of
   ₹10,000 hold under the Consumer Protection Act 2019 and the Indian
   Contract Act? What cap phrasing survives?
2. **Age 18 vs. DPDP "child" definition** — is our 18+ gate plus the fact that
   we process no children's data sufficient, or does the DPDP Act 2023 (s.9)
   invite new duties such as a verifiable guardian-consent flow? Recommend
   concrete UX if so.
3. **§79 IT Act safe-harbour posture** — is "intermediary" status defensible
   given there is *no* systematic proactive moderation, but we rate-limit and
   purge after 7 days? Any clause missing to preserve safe harbour?
4. **Copyright** — does the current notice-handling text need Indian Copyright
   Act references? Should a counter-notice procedure be formalised? Final
   verdict on the value of the DMCA registration (see walkthrough doc).
5. **Cross-jurisdiction** — GDPR applicability given we claim no personal-data
   processing: is the position defensible, or should we ship an Article 27
   (EU representative) arrangement or publish a transparent "no EU-contact
   point" statement?
6. **Criminal-law exposure** — malware/phishing/CSAM flowing through an
   anonymous endpoint: exposure under India's IT Act ss. 67, 67B, 69, 70,
   and 79(3); anything beyond the reactive model worth pre-arming (logging,
   wording with providers, escalation contacts)?
7. **Consumer-law status** — the service is free; does the Indian Consumer
   Protection Act still apply, and which of our disclaimers is best phrased to
   survive scrutiny?
8. **Incorporation timing** — at what usage scale would you advise forming an
   One Person Company / LLP, and getting tech-liability insurance?
9. **ToS change policy** — is "Last updated" + GitHub-releases announcement an
   adequate notice mechanism for binding users to revised terms?
10. **Venue clause** — "competent courts at the Operator's place of residence"
    — enforceable, or should a specific city be named publicly (with a privacy
    cost)?

## Honest residual-risk statement (already published)

The published Terms/Runbook explicitly state that neither documents nor MIT
licence provide immunity; residual risks (hosted-service abuse, personal
liability as sole individual, cross-border reach) are logged in
`docs/LEGAL-RUNBOOK.md` §7.

## Review outcome template

- [ ] Sign-off as-is by: ______ (name, bar enrolment number) on ______ (date)
- [ ] Punch list created; changes tracked in commits of the website repo.
