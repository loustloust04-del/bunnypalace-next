# Building from source

This guide gets you from a fresh clone to a running Debug build: the macOS app, the iOS app in the Simulator, and the tests. You don't need an Apple Developer account for any of it. You only need one to install on a physical device or to distribute.

- [Requirements](#requirements)
- [1. Clone and configure signing](#1-clone-and-configure-signing)
- [2. macOS app](#2-macos-app)
- [3. iOS app (Simulator)](#3-ios-app-simulator)
- [4. Tests](#4-tests)
- [Opening in Xcode](#opening-in-xcode)
- [Physical devices and distribution](#physical-devices-and-distribution)
- [Troubleshooting](#troubleshooting)

## Requirements

| What | Version | Needed for |
|---|---|---|
| macOS on Apple silicon | recent enough to run Xcode 26 | everything |
| **Xcode** | **26 or later** (iOS 26 SDK) | everything |
| [Homebrew](https://brew.sh) | any | installing the tools below |
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | 2.38 or later | everything. `project.yml` is the source of truth and the `.xcodeproj` is generated, not committed |
| [Bun](https://bun.sh) | **exactly 1.3.11** (pinned in `.bun-version`) | macOS app (it bundles the `cc-bridge` hub, compiled with `bun build --compile`) |
| meson, ninja, llvm, lld, libarchive, python3 | Homebrew's current | iOS app (it statically links [iSH](https://github.com/ish-app/ish) and bundles an Alpine Linux rootfs) |

The two apps have different extra requirements. The macOS app needs Bun but not the iSH toolchain. The iOS app needs the iSH toolchain but not Bun.

```sh
brew install xcodegen
# macOS app:
curl -fsSL https://bun.sh/install | bash -s "bun-v1.3.11"
# iOS app:
brew install meson ninja llvm lld libarchive
```

Don't use Bun 1.3.12. It truncates code signatures on arm64.

Xcode 26 ships the Metal toolchain as a separate download, and both apps compile `.metal` shaders. On a fresh Xcode install, fetch it once, or the build stops with "missing Metal Toolchain":

```sh
xcodebuild -downloadComponent MetalToolchain
```

## 1. Clone and configure signing

```sh
git clone https://github.com/replica882/mneme-atrium.git
cd mneme-atrium
cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig
```

`Config/Signing.local.xcconfig` is git-ignored and holds two values:

- `DEVELOPMENT_TEAM`: leave it **empty** for Simulator and local Mac builds.
- `MP_BUNDLE_ID_BASE`: the prefix every target's bundle ID is derived from. The default is `com.example.MemoryPalace`.

The example file works as-is for everything in sections 2–4. If this file is missing, `xcodegen generate` refuses to run on purpose. That way a build never silently picks up somebody else's bundle ID.

Package plugins and macros: one dependency (mlx-swift) ships a build plugin, and another uses Swift macros. Xcode asks you to trust them the first time. On the command line, every `xcodebuild` below passes `-skipPackagePluginValidation -skipMacroValidation` instead.

## 2. macOS app

```sh
xcodegen generate
xcodebuild -scheme MemoryPalace -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation \
  build
```

The first build resolves Swift packages (pinned by the committed `Package.resolved`) and runs the **Build cc-bridge binaries** phase. That phase:

- runs `bun install --frozen-lockfile` in `cc-bridge/`;
- compiles four helper binaries into `build/cc-bridge/`;
- signs them ad-hoc when no Developer ID is available.

Later builds skip the phase unless something under `cc-bridge/` changed.

The app lands in Xcode's DerivedData as `记忆花园.app`. To find it, run `xcodebuild -scheme MemoryPalace -showBuildSettings | grep -m1 BUILT_PRODUCTS_DIR`.

If Xcode stops with "requires a development team", you have two options:

- **Compile only** (this is what CI does): add `CODE_SIGNING_ALLOWED=NO`. This always builds, but an unsigned app may refuse to launch.
- **Run it locally**: sign ad-hoc instead:

```sh
xcodebuild -scheme MemoryPalace -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- \
  build
```

## 3. iOS app (Simulator)

The iOS app embeds an offline Linux sandbox. That needs a one-time bootstrap:

```sh
bash scripts/bootstrap-sandbox.sh
```

The bootstrap does three things, and it's safe to re-run:

1. Fetches the `deps/ish` submodule. It's deliberately **not** recursive; the iSH sub-submodules aren't needed.
2. Downloads Alpine Linux 3.21 and converts it into `deps/resources/alpine-rootfs.zip`. This step needs network access. The tarball's SHA-256 is checked against a value pinned in `scripts/prepare-rootfs.sh`.
3. Builds the iSH static libraries for `iphonesimulator` and `iphoneos` into `deps/libs/`.

After that, every iOS build re-runs `scripts/build-ish.sh` as a pre-build phase. It's incremental (under a second when nothing changed), but the Homebrew toolchain must stay installed.

Next, pick a Simulator:

```sh
xcrun simctl list devices available | grep -i iphone
```

Then generate the project and build, using the simulator's ID:

```sh
xcodegen generate
xcodebuild -scheme MemoryPalaceIOS -configuration Debug \
  -destination 'platform=iOS Simulator,id=<SIMULATOR-ID>' \
  -skipPackagePluginValidation -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Name a concrete simulator. Don't use `generic/platform=iOS Simulator`, which has no active architecture and compiles everything twice.

`CODE_SIGNING_ALLOWED=NO` sidesteps the entitlements (App Group, iCloud, HealthKit, push) that can't be signed without a team. The Simulator runs the app fine without them. Those features just won't work there.

## 4. Tests

The unit tests are hosted in the macOS app:

```sh
xcodebuild test -scheme MemoryPalaceTests \
  -destination 'platform=macOS' \
  -skipPackagePluginValidation -skipMacroValidation
```

The test host redirects its home directory to a temporary folder, so tests don't read or write your real library. To run one test class, add `-only-testing:MemoryPalaceTests/<TestClass>`.

The `cc-bridge` hub has its own test suite:

```sh
cd cc-bridge && bun install --frozen-lockfile && bun test
```

## Opening in Xcode

```sh
xcodegen generate && open MemoryPalace.xcodeproj
```

Run `xcodegen generate` again whenever you pull, switch branches, or edit `project.yml`. Never edit the `.xcodeproj` by hand, because the next generate overwrites it.

Xcode.app doesn't inherit your shell `PATH`. The build scripts already look in the standard Homebrew locations for the iSH toolchain, but not in `~/.bun/bin`. If the **Build cc-bridge binaries** phase fails with `bun: command not found`, build the macOS app once from Terminal (section 2). Its output is cached, so Xcode skips the phase afterwards until `cc-bridge/` changes.

Schemes:

| Scheme | What |
|---|---|
| `MemoryPalace` | macOS app (also builds the `mp-code` command-line tool) |
| `MemoryPalaceIOS` | iOS app, push notification extension, widget |
| `MemoryPalaceTests` | macOS unit tests |
| `StickerProbeUITests` | iOS UI tests |

## Physical devices and distribution

You need your own Apple Developer team for this.

1. In `Config/Signing.local.xcconfig`, set `DEVELOPMENT_TEAM` to your 10-character Team ID and `MP_BUNDLE_ID_BASE` to a reverse-DNS prefix you own. The targets derive their IDs from that prefix: `.ios`, `.ios.PushNSE`, `.ios.Widget`, `.mp-code`, `.tests`, `.ios.uitests`.
2. The App Group and iCloud container identifiers are still hardcoded in the `*.entitlements` files and in a few Swift constants. Change them to identifiers under your own prefix, or turn those capabilities off. Making them configurable is a known gap.
3. The `cc-bridge` helpers are signed by `scripts/build-cc-bridge.sh`, which picks its signing identity in this order:
   1. the `CC_BRIDGE_SIGN_IDENTITY` environment variable. Set it to `-` to force ad-hoc signing.
   2. a `Developer ID Application` certificate for `DEVELOPMENT_TEAM` in your keychain.
   3. ad-hoc.

   A Release build that has a team but no matching Developer ID fails on purpose, so you don't notarize an ad-hoc binary by accident.
4. **If you distribute a fork**, change `SUFeedURL` and `SUPublicEDKey` under the macOS target in `project.yml`, or disable Sparkle. Otherwise your users get offered upstream updates.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `xcodegen` stops with `没有 Config/Signing.local.xcconfig` | Run the `cp …example …` command from step 1. |
| `xcodegen: command not found` / version too old | `brew install xcodegen` / `brew upgrade xcodegen` (2.38 or later). |
| iOS pre-build fails with `缺 meson` / `缺 ninja` / `缺 brew llvm` / `缺 ld.lld` / `缺 libarchive` | `brew install meson ninja llvm lld libarchive`. `lld` is keg-only, but the script already looks in `/opt/homebrew/opt/lld/bin`. |
| `ish 子模块没拉` | `git submodule update --init deps/ish` (not `--recursive`), or re-run the bootstrap. |
| Link errors about `libish.a` / missing `alpine-rootfs.zip` | You skipped `bash scripts/bootstrap-sandbox.sh`. |
| Rootfs SHA-256 mismatch | The download was corrupt or the mirror changed. The script deletes the cached tarball, so re-run the bootstrap. To use a different Alpine version, pass `ALPINE_SHA256=<sha>` explicitly. |
| `missing Metal Toolchain` | `xcodebuild -downloadComponent MetalToolchain` (once per Xcode install). |
| Build stops at package plugin / macro trust | Add `-skipPackagePluginValidation -skipMacroValidation`, or click Trust in Xcode. |
| `Build cc-bridge binaries` fails with `bun: command not found` | Install Bun 1.3.11 and build once from Terminal. See [Opening in Xcode](#opening-in-xcode). |
| `bun version mismatch` warning | Install exactly 1.3.11: `curl -fsSL https://bun.sh/install \| bash -s "bun-v1.3.11"`. |
| Lots of Swift compiled twice on iOS | Use a concrete `-destination 'platform=iOS Simulator,id=…'`, not `generic/…`. |

The build scripts print some messages in Chinese. The fixes above match them by their key phrase.
