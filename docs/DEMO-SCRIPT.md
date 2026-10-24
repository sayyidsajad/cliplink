# 5-minute demo clip storyboard (for the launch posts)

Goal: a sub-30-second looping visual that proves the magic in one glance:
**Finder ⌘C → toast → link → browser → "expires" checker.**

## Recording (macOS built-in only)

1. `⌘⇧5` → "Record Entire Screen" (or area) → include mouse pointer.
2. Clean state beforehand: hide desktop icons (`defaults write com.apple.finder CreateDesktop -bool false && killall Finder` — undo later with `-bool true`), light
   wallpaper, terminal closed; share only ClipLink's own story.
3. Record once — do not edit much later; loop-able 20–28 s.

## Shot list (with on-screen pauses)

| # | Seconds | Action | What the viewer sees |
|---|---|---|---|
| 1 | 0:00–0:03 | Show desktop with a PDF named `quarterly-report.pdf` | Anchor file |
| 2 | 0:03–0:06 | Finder: select file → `⌘C` | ClipLink menu-bar icon lights up; **toast**: `✅ quarter-preview link copied` |
| 3 | 0:06–0:11 | Switch to Notes/Mail demo field → `⌘V` | Link appears (`https://api.cliplink.workers.dev/s/Ab3k`) |
| 4 | 0:11–0:17 | Open a browser with the link | Shared share page: fresh file name + "expires in about 24 hours" + big blue Download button |
| 5 | 0:17–0:22 | Click **Download file** once | File lands in Downloads; open it — same PDF |
| 6 | 0:22–0:26 | Menu-bar icon → **Revoke last link** | Badge flips "Revoked" |
| 7 | 0:26–0:28 | Refresh the browser page | Friendly "This link was revoked" state — end frame *stops* there for drama |

## Edit + export

- Crop to ~1280×720, 12–15 fps, GIF sized ≤ 4 MB (ezgif or `ffmpeg -i … -fs 4M`).
- Also export an MP4 (YouTube Shorts / X embed accepts it; GIF can't embed audio but you don't need it).

## Where to use

- Reddit post body + HN first comment + Product Hunt gallery frame 4.
- GitHub README (after the badges; GIF beats text — keep under 4MB so the repo
  stays snappy).
