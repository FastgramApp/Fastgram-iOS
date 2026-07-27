<div align="center">

<img src="docs/assets/fastgram-icon.png" alt="Fastgram" width="112" height="112">

# Fastgram for iOS

**An independent, open-source Telegram client for iOS, built around performance, efficiency,
and user control.**

[![TestFlight](https://img.shields.io/badge/TestFlight-join%20the%20beta-0D96F6.svg)](https://testflight.apple.com/join/UR1dU5sT)
[![Telegram](https://img.shields.io/badge/Telegram-%40fastgram__en-229ED9.svg)](https://t.me/fastgram_en)
[![Platform](https://img.shields.io/badge/platform-iOS-lightgrey.svg)](#build-it-yourself)
[![License](https://img.shields.io/badge/license-GPL--2.0--or--later-blue.svg)](COPYING)

</div>

---

Fastgram is the Telegram experience you already know, with work of its own underneath. The
project starts with a rebuilt video-message recording pipeline and grows from there — the
direction is an independent iOS client built around performance, efficiency and user control.

Fastgram is based on Telegram's open-source iOS client and uses the Telegram API. **It is not
affiliated with or endorsed by Telegram** — report problems you see in Fastgram here, not to
Telegram.

## Where it starts: video messages

Recording a video message took far more work on the device than it should. The capture pipeline
is rebuilt: frames are processed as NV12 directly in Metal instead of round-tripping through
BGRA and Core Image, with an optional lower capture resolution for dual capture.

In initial measurements on a single iPhone, the new pipeline used roughly **40% less CPU** and
processed each frame about **5× faster**, while keeping the original recording resolution. Those
are early results from one device and one setup — not a promise for every iPhone. Seeing how it
behaves in the real world is what testing is for.

Both pipelines ship: switch between them at any time in **Settings → Fastgram → Video Messages**.

Everything else is upstream Telegram-iOS. Internal Bazel targets and module names are still
called `Telegram` so upstream changes stay easy to merge; the installed app name, bundle
identifier and URL scheme are Fastgram's.

## Install

- **TestFlight beta:** [testflight.apple.com/join/UR1dU5sT](https://testflight.apple.com/join/UR1dU5sT)
- **Updates, release notes, benchmarks and known issues:**
  [@fastgram_en](https://t.me/fastgram_en)

Feedback from the beta is what tells us how the video-message pipeline behaves on hardware other
than one iPhone — bug reports are genuinely useful.

## Build it yourself

macOS, Xcode and Bazel versions are pinned in [`versions.json`](versions.json). Bazel is
downloaded automatically by the build wrapper. You will need your own Telegram `api_id` /
`api_hash`.

### Quick start

```bash
git clone --recursive -j8 https://github.com/FastgramApp/Fastgram-iOS.git
cd Fastgram-iOS
cp build-system/fastgram-configuration.example.json build-system/fastgram-local-configuration.json
```

Fill in your own Telegram `api_id` / `api_hash` from [my.telegram.org/apps](https://my.telegram.org/apps),
your Apple Team ID and a bundle identifier you control, then build for the simulator:

```bash
python3 build-system/Make/Make.py \
  --cacheDir="$HOME/telegram-bazel-cache" \
  build \
  --configurationPath=build-system/fastgram-local-configuration.json \
  --disableProvisioningProfiles \
  --buildNumber=1 \
  --configuration=debug_sim_arm64
```

Full instructions — Xcode project generation, device and distribution builds, tests,
troubleshooting — are in **[docs/BUILDING.md](docs/BUILDING.md)**.

### Credentials

`build-system/fastgram-local-configuration.json` is git-ignored and must stay that way. Never
commit API credentials, certificates, provisioning profiles or their passwords. CI reads
`FASTGRAM_BUNDLE_ID` / `FASTGRAM_TEAM_ID` / `FASTGRAM_APPSTORE_ID` from repository variables and
`FASTGRAM_API_ID` / `FASTGRAM_API_HASH` from encrypted secrets.

An API hash is compiled into every Telegram client and can ultimately be recovered from a
distributed binary. Keeping it out of Git protects it from casual reuse and from source-history
leaks; it does not make the shipped value secret.

## Repository layout

| Path | Contents |
| --- | --- |
| `Telegram/` | App target, extensions, app resources, watchOS snapshot |
| `submodules/` | The bulk of the code, as Bazel modules |
| `third-party/` | Vendored external dependencies |
| `build-system/` | Bazel wrapper (`Make.py`), build configurations, codesigning helpers |
| `docs/` | Architecture notes for the larger subsystems |

## Documentation

- [docs/BUILDING.md](docs/BUILDING.md) — building, signing, testing
- [docs/ui-testing.md](docs/ui-testing.md) — UI testing notes

Subsystem notes, for anyone working in those areas:

- [docs/richtext-composer.md](docs/richtext-composer.md) — composer and editor integration
- [docs/instantpage-richtext.md](docs/instantpage-richtext.md) — rich-message rendering
- [CLAUDE.md](CLAUDE.md) — orientation for AI coding assistants (and a decent map for humans)

## Contributing

Bug reports and focused pull requests are welcome — see
[CONTRIBUTING.md](.github/CONTRIBUTING.md) for the (short) rules. For anything security-related,
please follow [SECURITY.md](.github/SECURITY.md) instead of opening a public issue.

## License

Fastgram's modifications are licensed under the GNU General Public License, version 2 or any
later version — see [COPYING](COPYING) and [NOTICE.md](NOTICE.md).

The software license does not grant permission to use Fastgram's name, logo, icon or other brand
elements; see [TRADEMARKS.md](TRADEMARKS.md). Telegram and the Telegram logo are trademarks of
their respective owners.

## Credits

Fastgram exists because of the work of the [Telegram-iOS](https://github.com/TelegramMessenger/Telegram-iOS)
authors and everyone who contributed to it.
