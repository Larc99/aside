# Releasing

`scripts/make_app.sh` builds an ad-hoc signed app. That runs fine on your own
Mac, but Gatekeeper will block it on anyone else's until they right-click →
Open. Making a proper download needs a paid Apple Developer membership
(US$99/yr) and a **Developer ID Application** certificate — there is no free
path to notarization.

If you ever get one, the steps are:

```bash
# once
xcrun notarytool store-credentials aside-notary \
    --apple-id "you@example.com" --team-id "TEAMID" --password "app-specific-password"

# per release: bump VERSION in scripts/make_app.sh, then
swift test && scripts/make_app.sh

codesign --force --options runtime --timestamp \
    --sign "Developer ID Application: Your Name (TEAMID)" \
    --entitlements scripts/Aside.entitlements \
    build/Aside.app

ditto -c -k --keepParent build/Aside.app build/Aside.zip
xcrun notarytool submit build/Aside.zip --keychain-profile aside-notary --wait

xcrun stapler staple build/Aside.app
rm build/Aside.zip
ditto -c -k --keepParent build/Aside.app build/Aside.zip   # re-zip AFTER stapling

spctl --assess --type execute --verbose=4 build/Aside.app   # want: source=Notarized Developer ID
```

Two things here fail only on other people's Macs, so they are easy to miss:
`--options runtime` is required for notarization to pass at all, and the ticket
has to be stapled to the `.app` *before* you make the zip you actually upload.

On rejection, `xcrun notarytool log <submission-id> --keychain-profile
aside-notary` says which binary failed and why.
