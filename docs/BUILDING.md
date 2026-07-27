# Building Fastgram

Fastgram is built with [Bazel](https://bazel.build) through the `build-system/Make/Make.py`
wrapper, exactly like upstream Telegram-iOS. Internal Bazel targets and module names are still
called `Telegram` so that upstream changes can be merged with minimal friction — only the app
name, bundle identifier and URL scheme are Fastgram's.

## Requirements

| Tool  | Version |
| ----- | ------- |
| macOS | see `versions.json` (`macos`) |
| Xcode | see `versions.json` (`xcode`) |
| Bazel | pinned and downloaded automatically by `Make.py` (`versions.json`) |
| Python | 3.9+ |

`Make.py` verifies the installed Xcode against `versions.json` and refuses to build on a
mismatch. Pass `--overrideXcodeVersion` to skip that check.

## 1. Get the source

```bash
git clone --recursive -j8 https://github.com/FastgramApp/Fastgram-iOS.git
```

If you already cloned without `--recursive`:

```bash
git submodule update --init --recursive
```

## 2. Create your build configuration

API credentials and Apple account values are **not** committed. Copy the example and fill it in:

```bash
cp build-system/fastgram-configuration.example.json build-system/fastgram-local-configuration.json
chmod 600 build-system/fastgram-local-configuration.json
```

Replace the placeholders with your own values:

| Key | Where it comes from |
| --- | --- |
| `api_id`, `api_hash` | [my.telegram.org/apps](https://my.telegram.org/apps) |
| `team_id` | Keychain Access → your Apple Development certificate → Organizational Unit |
| `bundle_id` | A bundle identifier you control, e.g. `org.<random hex>.Fastgram` |

`build-system/fastgram-local-configuration.json` is listed in `.gitignore` — keep it that way.

Alternatively, generate the file from the environment (this is what CI does):

```bash
FASTGRAM_BUNDLE_ID=... FASTGRAM_API_ID=... FASTGRAM_API_HASH=... FASTGRAM_TEAM_ID=... \
  python3 build-system/Make/GenerateFastgramConfiguration.py
```

Optional variables: `FASTGRAM_APPSTORE_ID`, `FASTGRAM_URL_SCHEME`, `FASTGRAM_APP_CENTER_ID`,
`FASTGRAM_IS_INTERNAL_BUILD`, `FASTGRAM_IS_APPSTORE_BUILD`, `FASTGRAM_PREMIUM_IAP_PRODUCT_ID`,
`FASTGRAM_ENABLE_SIRI`, `FASTGRAM_ENABLE_ICLOUD`, `FASTGRAM_ENABLE_COMMUNICATION_NOTIFICATIONS`.

## 3. Build for the simulator

Simulator builds need no code signing:

```bash
python3 build-system/Make/Make.py \
  --cacheDir="$HOME/telegram-bazel-cache" \
  build \
  --configurationPath=build-system/fastgram-local-configuration.json \
  --disableProvisioningProfiles \
  --buildNumber=1 \
  --configuration=debug_sim_arm64
```

There is no selective per-module build — the only supported invocation builds the full
`Telegram/Telegram` target. The first build takes a long time; subsequent builds reuse the
Bazel cache in `--cacheDir`.

Add `--continueOnError` after `build` (it forwards Bazel's `--keep_going`) when you want every
error in one pass instead of stopping at the first failing target.

## 4. Generate an Xcode project

```bash
python3 build-system/Make/Make.py \
  --cacheDir="$HOME/telegram-bazel-cache" \
  generateProject \
  --configurationPath=build-system/fastgram-local-configuration.json \
  --xcodeManagedCodesigning
```

For simulator-only work you can also add `--disableProvisioningProfiles`.

## 5. Device and distribution builds

Device builds need real provisioning profiles. Copy `build-system/fake-codesigning` as a
reference for the required entitlements, create the matching profiles in your Apple Developer
account, and point the build at them:

```bash
python3 build-system/Make/Make.py \
  --cacheDir="$HOME/telegram-bazel-cache" \
  build \
  --configurationPath=build-system/fastgram-local-configuration.json \
  --codesigningInformationPath=/path/to/your/codesigning \
  --buildNumber=100001 \
  --configuration=release_arm64
```

`Make.py` can also pull signing material from a private Git repository via
`--gitCodesigningRepository`, `--gitCodesigningType` and `--gitCodesigningUseCurrent`; that
repository needs `TELEGRAM_CODESIGNING_GIT_PASSWORD` in the environment. Never commit
certificates, profiles or their passwords to this repository.

## Running tests

```bash
python3 build-system/Make/Make.py \
  --cacheDir="$HOME/telegram-bazel-cache" \
  test \
  --configurationPath=build-system/fastgram-local-configuration.json \
  --disableProvisioningProfiles \
  --target //submodules/TextFormat:TextFormatTests
```

App-side test coverage is thin: most modules have no tests, and the default `Tests/AllTests`
suite is currently unbuildable, so run individual targets with `--target`. The RichTextEditor
package keeps its own SwiftPM suite (`swift test`).

## Optional: embedding the watchOS app

The vendored watchOS client under `Telegram/WatchApp/` is **not** built by default. Add
`--embedWatchApp` to a device build (`debug_arm64` / `release_arm64`) together with
`--watchApiId`, `--watchApiHash`, `--watchSigningIdentity` and `--watchProvisioningProfile`.
Simulator builds never embed it.

## Troubleshooting

**Xcode is stuck at "build-request.json not updated yet".** Cancel the build and start a new
one.

**`Telegram_xcodeproj: no such package` after a restart.** Re-run the project generation step.

**A rebuilt app doesn't take effect on the simulator.** `simctl install` will not replace an
already-installed app when the build number is unchanged. Terminate the app and copy the freshly
built `.app` bundle over the installed one — the procedure is written out in
[CLAUDE.md](../CLAUDE.md#updating-the-running-simulator-after-a-rebuild-whole-app-copy).

## Upstream requirements

Telegram asks the following of everyone building a client on their API:

1. [Obtain your own `api_id`](https://core.telegram.org/api/obtaining_api_id).
2. Do not use the name Telegram for your app, or make sure users understand it is unofficial.
3. Do not use Telegram's standard logo (the white paper plane in a blue circle) as your app's logo.
4. Study the [security guidelines](https://core.telegram.org/mtproto/security_guidelines) and take
   good care of your users' data and privacy.
5. Publish your own source code in order to comply with the licences.
