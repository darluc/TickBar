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
4. Archives a universal Release app (`arm64` and `x86_64`).
5. Signs with hardened runtime and a secure timestamp, and verifies the signature.
6. Optionally notarizes, staples, and verifies the app.
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
- **App data appears missing after rename:** TickBar uses new bundle identifiers
  and an Application Support directory; old TickerBar data is not migrated automatically.
