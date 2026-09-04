# Shipping the iPhone app: TestFlight, then the App Store

Two channels, in this order:

1. **TestFlight** - builds don't expire after 7 days (unlike sideloading), testers install
   from a link, beta review is light. Use it now.
2. **App Store** - full review. Do it once the blockers in the last section are handled.

## One-time setup in App Store Connect

1. **Bundle ID** - developer.apple.com > Certificates, Identifiers & Profiles > Identifiers >
   `+` > App IDs > App. Bundle ID `com.cjvillafuerte.photobank` (explicit). No capabilities need
   ticking: background fetch and Bonjour are Info.plist keys, not entitlements.
2. **App record** - appstoreconnect.apple.com > Apps > `+`. Name (check it's free; "Photobank"
   probably isn't - "Photobank by CJ Villafuerte" works), primary language, bundle ID from step 1,
   SKU `photobank-ios`.
3. **API key** - App Store Connect > Users and Access > Integrations > App Store Connect API >
   Team Keys > Generate. Role **App Manager** (needed for Xcode's cloud-managed signing
   certificate). Download the `.p8` **once** - it can't be downloaded again. Note the
   **Key ID** and the **Issuer ID** shown above the table.
4. **Team ID** - developer.apple.com > Membership details (10 characters).

## Repository secrets (GitHub > Settings > Secrets and variables > Actions)

| Secret | Value |
|---|---|
| `APPLE_TEAM_ID` | the 10-character Team ID |
| `ASC_KEY_ID` | API key ID |
| `ASC_ISSUER_ID` | API issuer ID (UUID) |
| `ASC_API_KEY_P8_BASE64` | `base64 -i AuthKey_XXXXXXXXXX.p8 \| pbcopy` on the Mac |

From a terminal with `gh` logged in:

```bash
gh secret set APPLE_TEAM_ID
gh secret set ASC_KEY_ID
gh secret set ASC_ISSUER_ID
base64 -i ~/Downloads/AuthKey_XXXXXXXXXX.p8 | gh secret set ASC_API_KEY_P8_BASE64
```

Optional - only if cloud signing is refused (e.g. the team already has 3 distribution
certificates): export your Apple Distribution certificate from Xcode > Settings > Accounts >
Manage Certificates (right-click > Export) as a `.p12` and add
`IOS_DIST_CERT_P12_BASE64` (`base64 -i cert.p12`) and `IOS_DIST_CERT_PASSWORD`.

## Uploading a build

**From GitHub:** Actions > *TestFlight (signed iOS build + upload)* > Run workflow. Leave the
build number empty - the run number is used, so it always increases. ~10 minutes; the build
then shows in App Store Connect > TestFlight after Apple processes it (5-15 min).

**From the Mac instead:** `cd mobile && flutter build ipa --release --build-number=N` (N higher
than the last build TestFlight has), then drop `build/ios/ipa/*.ipa` on the **Transporter**
app. Xcode must be signed in to your Apple ID with the team selected once.

The marketing version comes from `pubspec.yaml` (`version: 0.2.0+1` -> 0.2.0). Bump it when
the App Store listing should show a new version; TestFlight only needs the build number to grow.

## Getting it onto phones

- **Internal testers** (your own App Store Connect users, up to 100): TestFlight tab > Internal
  Testing > `+` group > add the build. No review; install within minutes via the TestFlight app.
- **External testers** (anyone, up to 10,000, by public link or email): External Testing >
  group > add the build > fill in "What to test" > submit. The **first** build of a version
  goes through beta review (usually < 1 day); later builds of the same version are instant.
  Put the demo-server details below in the "Test information" so the reviewer can log in.

## Automated listing, review info and distribution (`fastlane/`)

Actions → *App Store Connect (listing / TestFlight distribution)* → Run workflow:

| Lane | What it does | Edit these files first |
|---|---|---|
| `metadata` | Pushes name, subtitle, description, keywords, promo text, release notes, URLs, categories, copyright; App Review contact + demo account + notes; App Privacy = data not collected. Creates the version in App Store Connect if needed. | `fastlane/metadata/**`, `fastlane/review_notes.txt` |
| `beta` | Distributes the latest processed TestFlight build to an external group (default "Friends") with What to Test + beta review info and submits it for beta review. `tester_email` invites one person (no App Store Connect account needed - just the TestFlight app). | `fastlane/whats_new.txt`, `fastlane/beta_description.txt` |
| `screenshots` | Uploads `fastlane/screenshots/<locale>/*.png` (6.9"/6.7"/6.5" iPhone sizes, device detected from filename). | drop PNGs in `fastlane/screenshots/en-US/` |

Extra secrets: `REVIEW_CONTACT_PHONE` (E.164, e.g. `+639171234567` - App Review's contact
phone, required before submission) and `DEMO_PASSWORD` (the demo server's).

Still manual (UI only): the age-rating questionnaire, agreements, and the final *Submit for
Review* click.

## Before the App Store submission

Blockers a reviewer will hit with the current app, in order of importance:

1. **A server the reviewer can reach.** The app does nothing without a Photobank server and
   App Review is not on your Wi-Fi. Host a demo instance over HTTPS (small VPS, or Tailscale
   Funnel / Cloudflare Tunnel in front of a machine at home) with a demo account holding a
   few sample photos, and put the URL + login in the review notes. (Immich does the same with
   `demo.immich.app`.) Plain HTTP will not work for the reviewer: the app allows HTTP on the
   local network only.
2. **Name** - must be unique on the store (see setup step 2).
3. **Listing assets** - screenshots for 6.7" and 6.5" iPhones (Simulator > File > Save Screen),
   description, keywords, support URL (the GitHub repo is fine), privacy policy URL
   (`https://github.com/cj-villafuerte/photobank/blob/main/PRIVACY.md`), age rating 4+.
   App Privacy questionnaire: **Data Not Collected** - true, there is no telemetry.
4. **"Free up space" deletes photos from the camera roll** - explain it in the review notes
   (below) so it isn't mistaken for data loss. The in-app confirmation stays.

Already handled in the project: `NSAllowsArbitraryLoads` removed (local-network HTTP only),
`ITSAppUsesNonExemptEncryption=false` (no export questionnaire per upload), usage strings for
Photos / Local Network / Bonjour, background modes declared.

### Review notes template

> Photobank is a companion app for a self-hosted photo server that users run on their own
> computer (open source: github.com/cj-villafuerte/photobank). It backs up the camera roll
> to that server over the home network.
>
> Demo server for review: https://demo.example.com  -  email: review@example.com  -
> password: ********  (enter the URL on the first screen, then log in).
>
> "Free up space" removes photos from the phone only after the server has confirmed, by
> checksum, that it holds a copy; every run shows a confirmation with the exact count first.
> Background Fetch is used to continue backups while the phone charges. No analytics or
> third-party services are used.
