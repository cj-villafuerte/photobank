# Photobank Theme

Single source of truth for the visual language of the **web app** (`web/src/index.css`)
and the **mobile app** (`mobile/lib/theme.dart`). Change a token here → update both files.

## Palette (dark, the only mode for now)

| Token        | Hex       | Usage                                            |
|--------------|-----------|--------------------------------------------------|
| `bg`         | `#101418` | App background                                   |
| `bg-raised`  | `#1A2027` | Cards, nav bars, sheets, inputs                  |
| `border`     | `#2A333D` | Hairline borders, dividers                       |
| `text`       | `#E8EDF2` | Primary text                                     |
| `text-dim`   | `#8B98A5` | Secondary text, labels, captions                 |
| `accent`     | `#4A9EFF` | Primary actions, links, focus, selection, progress |
| `danger`     | `#FF5C5C` | Destructive actions, errors                      |
| `on-accent`  | `#FFFFFF` | Text/icons on accent backgrounds                 |

Overlays: scrims/viewer chrome are black at 50–60% opacity (`rgba(0,0,0,.55)`).
Favorites use the ❤️ red family (web emoji / mobile `Colors.redAccent`) — not `danger`.

## Typography

- Web: `"Segoe UI", system-ui, sans-serif`. Mobile: platform default (SF Pro on iOS).
- Scale: page title ~22px semibold · section header ~17px semibold · body ~14–15px ·
  caption/meta ~12px in `text-dim`. No thin weights; regular + semibold only.

## Shape & spacing

- Radii: buttons/inputs **6px** · cards **10px** · sheets/dialogs **12px** ·
  photo thumbnails **4px** (web grid) / square-flush (mobile grid).
- Base spacing unit 4px; screen padding 16–20px; grid gutters 2–6px (photos sit tight).
- Borders are 1px `border`; elevation is expressed with `bg-raised` + border, not shadows.

## Components

- **Primary button**: `accent` fill, `on-accent` text, 6px radius, no border.
- **Secondary button**: `bg-raised` fill, 1px `border`, `text`; hover/focus ring `accent`.
- **Destructive**: secondary style with `danger` text, or `danger` fill for the final confirm.
- **Inputs**: `bg-raised` fill, 1px `border`, focus border `accent`, placeholder `text-dim`.
- **Photo grid**: square cells, cover-cropped; selection = 3px inset `accent` outline +
  accent check badge; video badge = black-scrim pill, top-right; favorite heart bottom-left.
- **Progress**: `accent` on `border` track.
- **Viewer/lightbox**: pure black backdrop, chrome on 55% black scrim.
- **Toasts/snackbars**: `bg-raised`, 1px `border`, 3px `accent` left edge (`danger` when error).

## Identity

App icon/emoji: 📷 · Display name: **Photobank** · Tone: quiet, dense, photo-first —
the UI stays dark and low-contrast so photos carry the color.
