# Photobank Privacy Policy

_Photobank is made by CJ Villafuerte. Last updated: September 4, 2026_

Photobank is self-hosted software. **Your photos, videos, and account data never leave
devices you control.**

## What the apps do with your data

- **Photobank desktop / server** stores the photos and videos you upload on the computer
  where it runs, in a folder you choose, plus a local database of metadata (dates, camera
  info, albums, favorites, text recognized in images). Nothing is sent to us or to any
  third party. The server has no telemetry, analytics, or crash reporting.
- **Photobank for iPhone** reads your photo library (with your permission) only to back it
  up to *your own* server on your local network, and — only when you choose — to remove
  items from the phone that the server has confirmed it holds. It uses your local network
  to find your server, and local notifications you can turn off. It contains no
  advertising or tracking SDKs.

## The one outside request: fonts

The web app and the iPhone app load their typefaces (Bricolage Grotesque, Instrument Sans,
DM Mono) from Google Fonts when they start. Like any web font, that request shows Google your
IP address and nothing else about you or your library. Nothing else in Photobank contacts a
third party.

## Public demo server

The demo at photobank-demo-production.up.railway.app is a shared, read-only sandbox we host
for trying the app: whatever you upload there is deleted automatically after a minute and
is visible to other visitors until then. Don't put private photos on it.

## Accounts

Accounts exist only on your server. Passwords are stored as salted Argon2 hashes.
We (the developers) have no access to your server, accounts, or media.

## Data we collect

None. We operate no servers that receive data from Photobank.

## Your control

Everything is deletable by you: remove media in the app or web UI, empty the trash,
delete the server's storage folder, or uninstall the apps. The iPhone app's
_Settings → App data_ erases its local records and cache at any time.

## Contact

Questions: open an issue at https://github.com/cj-villafuerte/photobank/issues
