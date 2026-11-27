# TickBar Release Guide

Repository: <https://github.com/darluc/TickBar>

## CI

`.github/workflows/ci.yml` generates the Xcode project and builds/tests the Debug
scheme on macOS for pushes and pull requests to `main`, or manual dispatch.
Test results are uploaded as an `.xcresult` artifact, including on test failure.
CI does not need signing secrets.

## Required Developer ID signing setup

Releases **require Developer ID Application signing**. There is no ad-hoc fallback.
An Apple Development or Apple Distribution certificate is not a substitute.

1. Join the Apple Developer Program and obtain a **Developer ID Application**
   certificate with its private key.
2. In Keychain Access, select the certificate and its private key and export them
   as a password-protected `.p12` file. Do not commit or upload this file as an artifact.
3. Configure these Actions secrets in **darluc/TickBar**, not the deleted repository:

| Secret | Required | Value |
|---|---|---|
| `MAC_DEVELOPER_ID_P12_BASE64` | Yes | Base64-encoded `.p12`, containing certificate and private key |
| `MAC_DEVELOPER_ID_P12_PASSWORD` | Yes | Password protecting the `.p12` |
| `APPLE_TEAM_ID` | Yes | Team ID matching the Developer ID Application certificate |
| `MAC_DEVELOPER_ID_PROVISIONING_PROFILE_BASE64` | Yes | Base64-encoded **Mac Developer ID** `.provisionprofile` for `app.tickbar.TickBar` (must include iCloud / Key-Value if watchlist sync is enabled) |
| `APPLE_ID` | For notarization | Apple account email |
| `APPLE_APP_SPECIFIC_PASSWORD` | For notarization | App-specific password generated at <https://account.apple.com> |

Upload the certificate without printing its contents:

```bash
base64 -i /path/to/developer-id.p12 | gh secret set MAC_DEVELOPER_ID_P12_BASE64 --repo darluc/TickBar
# These commands prompt for secret values rather than putting them in shell history:
gh secret set MAC_DEVELOPER_ID_P12_PASSWORD --repo darluc/TickBar
gh secret set APPLE_TEAM_ID --repo darluc/TickBar
gh secret set APPLE_ID --repo darluc/TickBar
gh secret set APPLE_APP_SPECIFIC_PASSWORD --repo darluc/TickBar
```

### Mac Developer ID provisioning profile (required for iCloud on CI)

GitHub runners have **no Xcode Apple ID login**, so release builds use **manual signing**
with a checked-in secret profile—not Automatic signing.

1. On [Identifiers](https://developer.apple.com/account/resources/identifiers/list), register
   **`app.tickbar.TickBar`** (if missing) and enable **iCloud** (Key-value storage is enough).
2. [Profiles](https://developer.apple.com/account/resources/profiles/list) → **+** → **macOS** →
   **Developer ID** → App ID **`app.tickbar.TickBar`** → your **Developer ID Application**
   certificate → download the `.provisionprofile`.
3. Upload the profile (do not commit the file):

```bash
base64 -i /path/to/TickBar_Mac_Developer_ID.provisionprofile | \
  gh secret set MAC_DEVELOPER_ID_PROVISIONING_PROFILE_BASE64 --repo darluc/TickBar
```

Re-run the failed release after the secret is set.

The runner generates its own temporary keychain password. `MAC_KEYCHAIN_PASSWORD`
is no longer required. The temporary certificate and keychain are removed even if
a build fails.

### Signing versus notarization

Developer ID signing is mandatory. Notarization runs when **both** Apple ID
secrets are configured. Setting only one fails configuration validation.
Without either, the workflow warns and publishes signed, **not notarized** builds;
Gatekeeper may block downloaded builds. Configure both for normal public distribution.
Notarization, stapling, and verification failures block publication when enabled.

## Publish a release

Versions must contain two or three numeric components, optionally prefixed with
`v`, such as `2026.1`, `2026.1.0`, or `v2026.1`.

### Tag-triggered release

After CI passes on the desired commit:

```bash
git tag 2026.1
git push origin 2026.1
```

### Manual release

In GitHub Actions, select **Release → Run workflow**, choose `main`, and enter a
version. Or use:

```bash
gh workflow run release.yml --repo darluc/TickBar --ref main -f version=2026.1
```

A missing tag is created at the workflow's checked-out commit after packaging.
If the tag already exists, it must point to that same commit; otherwise select
that tag as the workflow ref instead of `main`.

The release workflow:

1. Validates version/tag and required signing secrets.
2. Generates the project and builds/runs the Debug tests.
3. Imports the certificate and requires a valid **Developer ID Application**
   identity matching `APPLE_TEAM_ID`.
4. **Unsigned** `archive` (`CODE_SIGNING_ALLOWED=NO` — SPM dependencies must not get a provisioning profile).
5. **Exports** with Manual Developer ID + the provisioning profile secret (signs only `TickBar.app`, embeds iCloud KVS from the profile).
6. Verifies the exported app signature and `ubiquity-kvstore-identifier`.
7. Packages the ZIP and signs the DMG; optionally notarizes and staples the DMG.
8. Uploads Actions artifacts and publishes a GitHub Release. Re-running a release
   replaces its ZIP/DMG assets without deleting its release notes or the release.

Artifacts: `TickBar-<version>.zip` and `TickBar-<version>.dmg`.
Test result bundles are also uploaded for diagnosis.

There is no Sparkle/appcast generation in this pipeline. The app's current update
checker uses GitHub Releases; publishing a release is the update-discovery step.

## Local validation

```bash
xcodegen generate
xcodebuild -project TickBar.xcodeproj -scheme TickBar \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO test
```

For a local release build, `make release-build VERSION=2026.1` remains available.
The Makefile has its own signing behavior; the mandatory signing policy described
above applies to the GitHub release workflow.

## Troubleshooting

- **Missing signing secrets:** new repositories do not inherit secrets from a
  deleted repository. Check `gh secret list --repo darluc/TickBar` (values are not shown).
- **No matching signing identity:** ensure the `.p12` contains the private key,
  the certificate is valid, and `APPLE_TEAM_ID` matches. Check local identities with
  `security find-identity -v -p codesigning`.
- **Notarization rejected:** inspect the notarytool submission log for entitlement
  or signature errors. Do not bypass verification to publish a failed submission.
- **GRDB / swift-nio "does not support provisioning profiles" on archive:** do not pass
  `PROVISIONING_PROFILE_SPECIFIER` to the whole `archive` command; archive unsigned and
  sign only at `exportArchive`.
- **iCloud watchlist sync greyed out on a release build:** confirm
  `codesign -d --entitlements :- /Applications/TickBar.app` lists
  `com.apple.developer.ubiquity-kvstore-identifier` as `<TEAM_ID>.app.tickbar.TickBar`.
- **App data after rename:** on launch, TickBar imports the old TickerBar database
  and preferences once. Missing watchlists, stocks, holdings, alerts and settings
  are merged into an existing TickBar database; current records win ID conflicts.
  Debug and Release data stay separate. The legacy database is retained, and
  consistent SQLite backups of both databases are saved under
  `~/Library/Application Support/TickBar/MigrationBackups/<ID>/` (Debug uses
  `TickBar-Dev`). A migration marker prevents deleted items from being restored
  again on later launches. TickerBar data takes priority over older PanBar data.
