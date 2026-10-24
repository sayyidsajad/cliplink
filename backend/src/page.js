// HTML pages served for humans: download page + error pages.

export function escapeHTML(s) {
  return String(s)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

export function humanBytes(n) {
  n = Number(n);
  if (!Number.isFinite(n) || n < 0) return "unknown size";
  if (n < 1024) return `${n} B`;
  const units = ["KB", "MB", "GB", "TB"];
  let v = n / 1024;
  let i = 0;
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
  return `${v >= 100 ? Math.round(v) : v.toFixed(1)} ${units[i]}`;
}

export function untilText(expiresAt, now) {
  const ms = expiresAt - now;
  if (ms <= 0) return "This link has expired.";
  const min = Math.max(1, Math.round(ms / 60000));
  if (min < 60) return `Expires in about ${min} minute${min === 1 ? "" : "s"}.`;
  const h = Math.round(min / 60);
  if (h < 48) return `Expires in about ${h} hour${h === 1 ? "" : "s"}.`;
  const d = Math.round(h / 24);
  return `Expires in about ${d} day${d === 1 ? "" : "s"}.`;
}

const style = `
:root { color-scheme: light dark; }
* { box-sizing: border-box; }
body {
  margin: 0; min-height: 100vh; display: grid; place-items: center;
  background: #0e1016; color: #e8eaf1;
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
  padding: 24px;
}
.card {
  width: min(560px, 94vw); background: #161a22; border: 1px solid #262c3a;
  border-radius: 18px; padding: 30px 32px; box-shadow: 0 20px 70px rgba(0,0,0,.5);
}
h1 { font-size: 17px; font-weight: 600; margin: 0 0 2px; color: #9aa3b5; letter-spacing: .02em; }
.file {
  font-size: 22px; font-weight: 700; margin: 6px 0 18px; word-break: break-all;
}
.meta { display: grid; gap: 8px; margin: 0 0 24px; }
.meta div { display: flex; gap: 10px; font-size: 14px; color: #aab3c5; }
.meta span { color: #e8eaf1; }
.btn {
  display: inline-block; padding: 12px 22px; border-radius: 12px; text-decoration: none;
  background: linear-gradient(135deg, #3b82f6, #6366f1); color: #fff; font-weight: 600; font-size: 15px;
}
.btn:hover { filter: brightness(1.08); }
.footer { margin-top: 26px; font-size: 12px; color: #6b7280; }
.banner {
  border-radius: 10px; padding: 12px 14px; font-size: 14px; margin-bottom: 18px;
  background: #7f1d1d33; border: 1px solid #b91c1c55; color: #fca5a5;
}
.banner.warn { background: #78350f33; border-color: #b4530955; color: #fcd34d; }
@media (prefers-color-scheme: light) {
  body { background: #eef1f6; color: #16181d; }
  .card { background: #ffffff; border-color: #e3e7ef; box-shadow: 0 14px 40px rgba(15,23,42,.12); }
  h1, .meta div, .footer { color: #667085; }
  .file, .meta span { color: #16181d; }
  .banner { background: #fef2f2; border-color: #fecaca; color: #b91c1c; }
  .banner.warn { background: #fffbeb; border-color: #fde68a; color: #92400e; }
}
`;

function page(title, inner) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>${escapeHTML(title)}</title>
<style>${style}</style>
</head>
<body>
<div class="card">
${inner}
<div class="footer">Shared with ClipLink · files expire automatically; the recipient needs only a browser.<br>
<a href="https://sayyidsajad.github.io/cliplink-website/terms.html" style="color:inherit">Terms</a> · <a href="https://sayyidsajad.github.io/cliplink-website/privacy.html" style="color:inherit">Privacy</a> · <a href="https://github.com/sayyidsajad/cliplink/issues/new?template=abuse-report.md" style="color:inherit">Report abuse</a></div>
</div>
</body>
</html>`;
}

export function sharePage({ filename, size, expiresAt, now, token }) {
  return page("ClipLink download", `
<h1>Someone shared a file with you</h1>
<div class="file">${escapeHTML(filename)}</div>
<div class="banner warn">${escapeHTML(untilText(expiresAt, now))}</div>
<div class="meta">
  <div>File&nbsp;size <span>${escapeHTML(humanBytes(size))}</span></div>
  <div>Works&nbsp;with <span>any modern browser — no account, no app required</span></div>
</div>
<a class="btn" href="/api/v1/shares/${encodeURIComponent(token)}/download">Download file</a>`);
}

export function errorPage({ status, title, message }) {
  return page(`ClipLink — ${title}`, `
<h1>ClipLink</h1>
<div class="file">${escapeHTML(title)}</div>
<div class="banner">${escapeHTML(message)}</div>
<div class="meta"><div>HTTP&nbsp;status <span>${status}</span></div></div>`);
}
