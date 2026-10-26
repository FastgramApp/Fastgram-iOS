# TestFlight releases

Fastgram's previous releases were built locally with Bazel, signed with Apple
Distribution, and uploaded as an IPA using Apple's Transporter app. The latest
local archive before the October 2026 upstream sync was **1.0 (9)**, built from
`de873252c7`.

## Build

Use the next unused build number in App Store Connect. Keep CarPlay development
on its feature branch and build the release from the upstream-sync branch or
`master`. Keep the app version in `versions.json` at Fastgram's version, rather
than adopting Telegram's version number.

The existing distribution signing material lives outside the repository at
`~/Documents/Fastgram/Signing`: seven App Store profiles in `profiles/` and a
distribution certificate in `certs/`. The matching signing identity must be
available in the login keychain. Never commit signing material or API credentials.

```sh
python3 build-system/Make/Make.py \
  --cacheDir "$HOME/telegram-bazel-cache" \
  build \
  --configurationPath /path/to/private-release-configuration.json \
  --codesigningInformationPath "$HOME/Documents/Fastgram/Signing" \
  --buildNumber 10 \
  --configuration release_arm64
```

The configuration uses Fastgram's bundle ID and team, `is_appstore_build=true`,
`is_internal_build=false`, and the release's intended capabilities. For a build
from the separate CarPlay branch, its distribution profile must also contain
CarPlay Communication if that feature is enabled.

## Archive and verify

Copy the fresh `bazel-bin/Telegram/Telegram.ipa` to
`~/Documents/Fastgram/Releases/1.0 (<build>)/Fastgram-1.0-<build>.ipa`. Archive the
generated dSYMs alongside it and write SHA-256 checksums. Record the source commit
and build command with the archive. Extract the IPA to verify its app version,
build number, bundle IDs, signatures, and distribution profiles. All six app
extensions must be present. Use the IPA as the source; `Telegram_archive-root/`
can contain stale binaries after a cache hit.

## Upload

Open **Transporter**, sign in to the appropriate App Store Connect account, add
the IPA, and select **Deliver**. After Apple processes the upload, open the app's
**TestFlight** tab in App Store Connect and verify the build before adding it to
the intended tester group. An upload alone does not verify runtime behavior.

Apple documents Transporter and the other upload methods in
[Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/).

## Restore device development

Release builds replace the generated configuration repository with distribution
profiles. Direct installation from Xcode then fails with `0xe800801f` until the
development project is regenerated. After switching back to the development
branch, run:

```sh
python3 build-system/Make/Make.py \
  --cacheDir "$HOME/telegram-bazel-cache" \
  generateProject \
  --configurationPath build-system/fastgram-local-configuration.json \
  --xcodeManagedCodesigning \
  --disableProvisioningProfiles
```

Use `--overrideXcodeVersion` only if the development branch pins an older Xcode
than the installed version. This restores development signing without changing
the archived release IPA.
