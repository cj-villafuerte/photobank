# Photobank Theme — "Brief"

Ink on paper. One accent. Everything else is type and hairlines.
Source of truth for `web/src/index.css` (web + desktop app) and `mobile/lib/theme.dart`.

## Principles
- **Paper, not screen.** White background, no gradients, shadows, glass, or dark mode.
- **One accent per composition.** `accent` appears as the point of the sentence: an eyebrow
  number, a headline's period, an arrow, a favorite mark, an alert value. Never a fill.
- **Headlines are sentences.** Sentence case, ending in a period (`Timeline.`).
- **Structure is drawn, not filled.** Hairlines and thin borders; surfaces near-white, sparingly.
- **Numbered, not bulleted.** Section eyebrows: `01 PROFILE`, `02 PHONE STORAGE`.
- **Mono is metadata.** Labels, tags, timestamps, sizes, specs → DM Mono, uppercase, tracked.
- Photos carry the color. The UI stays neutral so the grid reads as the subject.

## Color
| Token | Hex | Use |
|---|---|---|
| `paper` | `#FFFFFF` | page background |
| `surface` | `#F5F6F7` | cards, table backgrounds, chips, inputs |
| `surface2` | `#ECEEF1` | nested surfaces, hover |
| `ink` | `#101418` | headlines, primary text, primary buttons |
| `ink2` | `#2B3239` | secondary headline segments, chart bars |
| `muted` | `#4B535C` | body copy |
| `faint` | `#7B848E` | eyebrows, footers, tertiary metadata |
| `line` | `#E3E6EA` | hairlines, card borders |
| `line2` | `#B9C0C8` | emphasized rules (table header underline) |
| `accent` | `#FF4A1C` | eyebrow numbers, headline period, arrows, favorite mark, alerts/destructive text, selected chart bar |

Inverted panels (viewer/lightbox): `ink` background, `paper` text, accent unchanged.

## Typography (Google Fonts)
- **Display — Bricolage Grotesque** 600/700/800, tracking −1.5% to −2%, line-height 1.05, sentence case + period.
- **Body — Instrument Sans** 400/500, line-height 1.45.
- **Mono — DM Mono** 400/500, +14% tracking, UPPERCASE: eyebrows, tags, badges, table headers, nav labels.

Web scale (1440 viewport): page title 40, section 30, card title 20, body 15, eyebrow 11, tag 11.
Mobile: title 28, section 20, body 15, eyebrow 11, tag 10.

## Shape & structure
- Radius **6px** everywhere; no pills.
- Borders 1px `line`; emphasized rules `line2`. No shadows.
- Buttons: ink on paper (hairline border) or paper on ink (primary). Never accent-filled.
  Destructive: `accent` text on paper.
- Photo grid: square, cover-cropped, 2px gutters; selection = 2px `ink` inset outline + ink check;
  badges = `ink` at 80% with `paper` mono text; favorite = accent rounded square (the logo period).
- Eyebrow pattern: `01  PROFILE` — number in accent, label in faint, both mono medium.
- Wordmark: `Photobank.` display 700, period in accent. No maker tag next to it: the credit
  lives in the website footer, README, PRIVACY.md and one mono line at the end of the phone's
  Settings.

## Deviation for apps
The brief's "no icons" rule is for compositions; touch UIs keep a minimal functional set
(nav tabs, play, close, chevrons) in `ink`/`faint`, always paired with a mono label.
