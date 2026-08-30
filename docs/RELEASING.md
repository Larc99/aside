# Releasing

`scripts/make_app.sh` ad-hoc signs by default, which is right for local builds
and CI but will not pass Gatekeeper on anyone else's Mac. Distributable builds
go through `scripts/release.sh`, which signs with a Developer ID, notarizes,
staples the ticket and leaves a zip ready to upload.

## One-time setup

You need a paid Apple Developer membership and a **Developer ID Application**
certificate — not "Apple Development" (local only) and not "Apple Distribution"
(App Store only). Check what you have:

```bash
security find-identity -v -p codesigning
```

Then store notarization credentials once, using an app-specific password
created at appleid.apple.com:

```bash
xcrun notarytool store-credentials aside-notary \
    --apple-id "you@example.com" --team-id "TEAMID" --password "app-specific-password"
```

## Cutting a release

```bash
# 1. Bump VERSION in scripts/make_app.sh, then:
swift test

# 2. Build, sign, notarize, staple, verify — all of it:
export ASIDE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
scripts/release.sh

# 3. Tag and publish, attaching the zip:
git tag -a v0.2.0 -m "Aside 0.2.0"
git push origin v0.2.0
gh release create v0.2.0 --title "Aside 0.2.0" --notes "..." build/Aside.zip
```

`release.sh` ends by running `spctl --assess`, which must report
`source=Notarized Developer ID`. That is the check that reflects what a
downloader actually gets — a build that works on your Mac proves nothing,
because your own builds are never quarantined.

## Things that fail only on other people's Macs

- **The hardened runtime** (`--options runtime`) is required for notarization
  and cannot be added after signing. `make_app.sh` applies it whenever
  `ASIDE_SIGN_IDENTITY` is set.
- **The ticket staples to the `.app`, not the zip.** The archive you upload has
  to be built *after* stapling. `release.sh` deliberately zips twice for this
  reason; do not "optimise" the second one away.
- **Entitlements must stay attached.** Dropping them breaks the sandbox and the
  sync-folder security-scoped bookmark.

On rejection, `xcrun notarytool log <submission-id> --keychain-profile
aside-notary` names the offending binary and why.

## Third-party obligations

Any distributed build carries the bundled fonts, so it carries their licence
too. `make_app.sh` copies `Sources/Aside/Resources/Fonts/` wholesale, which
includes `OFL.txt` — do not tidy that file out of the resource copy.
