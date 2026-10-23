# strayflag

**Find leftover debug, mock and unlock switches in your release build before App Review does.**

`strayflag` opens the artifact you are about to upload (`.ipa`, `.xcarchive`, `.apk`, `.aab`), finds
where your app's code actually lives for Flutter, Unity, React Native or native apps, pulls out the string
literals and flags names like `enableUnlockedMockPurchases`, `screenshots-mode` or `DEV_MENU`. It runs
as a CLI or as a GitHub Action, and it can write the *Notes for Review* section for the flags you keep
on purpose.

```text
$ strayflag scan build/ios/ipa/Runner.ipa
strayflag 0.1.0  build/ios/ipa/Runner.ipa
Platform: ios   Framework: Flutter
Scanned:
  • Payload/Runner.app/Frameworks/App.framework/App  (Flutter app code (Dart AOT snapshot), ...)
  • Payload/Runner.app/Runner  (main executable, ...)

Suspicious strings (4):
  Payload/Runner.app/Frameworks/App.framework/App
  HIGH    "enableUnlockedMockPurchases"
          matched: unlocked mock, mock purchase  [string @0x353]
  MEDIUM  "Internal dev menu"
          matched: dev menu  [string @0x378]
  MEDIUM  "screenshots-mode"
          matched: screenshot mode, screenshots mode  [string @0x31f]
  MEDIUM  "slow-entitlement"
          matched: slow entitlement  [string @0x339]

✗ FAIL — remove these switches from release builds, add true false positives to `allow:`,
or declare intentional ones under `features:` so they go into Notes for Review.
```

## Why

In October 2026 Apple moved hidden features into their own App Review guideline, **2.5.19**: hiding
features (for example through obfuscation) can lead to removal from the App Store and termination of the
developer account. Guideline **2.3.1(a)** still requires new features to be described in *Notes for
Review*.

A test switch you forgot about now looks like a hidden feature. Developers have been rejected for flags such as
`screenshots-mode`, `slow-entitlement` and `UnlockedMockPurchases` that were left in a release build.
The usual fix is to run `strings` on every archive by hand. Existing pre-submission checkers read Swift,
Objective-C or React Native **source**, so they skip Flutter and Unity apps, where the shipped code is a
Dart AOT snapshot or IL2CPP metadata.

`strayflag` checks the **built artifact**, which is what Apple actually receives.

## Install

```sh
dart pub global activate strayflag     # needs Dart 3.5+ (bundled with Flutter)
strayflag --help
```

Or build a standalone binary (no Dart needed to run it):

```sh
git clone https://github.com/artonglocke/strayflag && cd strayflag
dart pub get && dart compile exe bin/strayflag.dart -o strayflag
```

## Usage

```sh
strayflag scan Runner.ipa                       # text report, exit 1 on findings
strayflag scan build/app/outputs/bundle/release/app-release.aab
strayflag scan MyGame.xcarchive --json          # JSON on stdout
strayflag scan Runner.ipa --baseline last.json  # only strings that are NEW since last release
strayflag scan Runner.ipa --baseline v1.4.ipa   # ...or compare against the previous build directly
strayflag scan Runner.ipa --notes-out notes.md  # write the Notes for Review section
strayflag scan Runner.ipa --min-severity low    # show the noisy generic matches too
strayflag scan Runner.ipa --deep                # also scan every plugin, extension, .so and DEX
strayflag notes                                 # Notes for Review from the config alone
strayflag init                                  # write a commented .strayflag.yaml
strayflag rules                                 # list the built-in denylist
```

| Exit code | Meaning |
|---|---|
| `0` | Clean (nothing at or above `fail_on`) |
| `1` | Findings, or expected strings missing when `fail_on_missing_expected: true` |
| `2` | Error: unreadable artifact, bad config, bad arguments |

Other options: `--config FILE`, `--fail-on low|medium|high|never`, `--json-out FILE`,
`--markdown-out FILE` (appends, so it works with `$GITHUB_STEP_SUMMARY`), `--[no-]color`.

### What gets scanned

| Build | Files read |
|---|---|
| Flutter iOS | `Payload/*.app/Frameworks/App.framework/App` (Dart AOT snapshot) + main executable |
| Flutter Android | `lib/<abi>/libapp.so` (one ABI, arm64 preferred) |
| Unity IL2CPP iOS | `Data/Managed/Metadata/global-metadata.dat` (string literal table and type/method names) + `UnityFramework` |
| Unity IL2CPP Android | `assets/bin/Data/Managed/Metadata/global-metadata.dat` + `lib/<abi>/libil2cpp.so` |
| React Native | `main.jsbundle` / `assets/index.android.bundle` |
| Native / unknown | iOS main executable; Android `classes*.dex` |
| `--deep` | additionally every Mach-O/dylib in the bundle, every `.so` of the chosen ABI and all DEX files |

Strings are read with exact boundaries where the format allows it: Flutter's Dart string table (Latin-1 and
UTF-16 strings), the Unity IL2CPP literal table and Android's DEX string table. Everything else gets a UTF-8-aware
`strings` scan. Localized text such as `Testni način: otključaj sve premium značajke` or
`…build yet — upgrading simply unlocks Premium…` comes out whole, not cut at the first `č` or `—`.

Flutter's `--obfuscate` renames classes and methods but **keeps string literals readable**, so
`'enableUnlockedMockPurchases'` used as a map key, a remote-config key or a widget label still shows up.
For Unity, the IL2CPP literal table gives clean, separate strings, and class/method names
such as `CheatMenuController` are checked as well.

### How matching works

Every string is split into words with camelCase, PascalCase, snake_case, kebab-case and `ACRONYMWord` handling
(`enableUnlockedMockPurchases` becomes `enable unlocked mock purchases`). Denylist terms only match whole words, with simple
plurals and tenses, or the same words glued together (`devmenu`, `TESTMODE`). `contestmode`, `cheatsheet` and
`device menu` do not match.

Terms have a severity:

- **high**: unlocks paid content or hides functionality (`mock purchase`, `unlock all`, `premium override`,
  `bypass paywall`, `god mode`, `cheat menu`, `backdoor`, …)
- **medium**: test and debug switches (`dev menu`, `debug panel`, `screenshot mode`, `test mode`, `fake data`,
  `skip login`, `staging api`, `cheat`, non-production URLs such as `https://staging.api…` or `*.ngrok.app`, …)
- **low**: generic words (`debug`, `mock`, `test`, `staging`, `bypass`, `localhost`, …). These appear in
  framework code in every build, so they are hidden by default.

By default the report shows **medium and above** and fails on **medium and above**. On a real obfuscated
`flutter build apk --release`, the default settings report nothing from the Flutter framework itself.

## Configuration: `.strayflag.yaml`

Looked up in the working directory, or passed with `--config`. Every key is optional.

```yaml
fail_on: medium          # low | medium | high
min_severity: medium     # what the report shows

deny:                    # extra terms (plain = medium)
  - qa build
  - term: free coins
    severity: high

disable:                 # built-in terms you never want
  - ngrok

allow:                   # known false positives: case-insensitive substring, or re:<regex>
  - "Debug output"
  - "re:^https://staging-docs\\.example\\.com"

features:                # flag-gated features you keep ON PURPOSE
  - name: Screenshot mode
    flags: [screenshots-mode]          # strings in the binary that belong to this feature
    description: Fills the app with sample data for App Store screenshots. No purchases are unlocked.
    how_to_enable: Not reachable by users. Our UI test runner sets the launch argument -screenshots-mode.

expect:                  # strings a real release must contain
  - com.example.app.pro_monthly
fail_on_missing_expected: false

notes_intro: "Demo account details are in App Review Information."
```

- **features**: matching strings are listed as *declared* instead of failing the build, and each feature
  goes into the generated *Notes for Review* section.
- **expect**: a quick check that the release isn't wired to mocks. If a real product ID or purchase class
  is missing from the scanned code, you get a warning, or a failure with `fail_on_missing_expected: true`.

Generated *Notes for Review* (`--notes-out notes.md` or `strayflag notes`):

```markdown
## Notes for Review

This build contains the following feature that is controlled by a flag or not visible on first launch. Each is described below with the steps to reach it.

1. **Screenshot mode**
   - What it does: Fills the app with sample recipes so App Store screenshots look the same in every language. It does not unlock any paid content.
   - How to enable it: Not reachable by users. Our UI test runner starts the app with the launch argument -screenshots-mode.
```

## Baselines

Old apps often have harmless matches that you don't want to clean up today. Save a report once and
only fail on strings that are **new**:

```sh
strayflag scan Runner.ipa --fail-on never --json-out .strayflag-baseline.json   # commit this file
strayflag scan Runner.ipa --baseline .strayflag-baseline.json
```

The JSON report keeps every suspicious string at all severities under `"baseline"`, so any report can be
used as a baseline. You can also pass the previous `.ipa` / `.aab` directly.

## GitHub Action

```yaml
# .github/workflows/release.yml (excerpt)
- run: flutter build ipa --release --obfuscate --split-debug-info=build/symbols

- name: Check for leftover test switches
  uses: artonglocke/strayflag@v0
  with:
    path: build/ios/ipa/*.ipa         # or build/app/outputs/bundle/release/app-release.aab
    # config: .strayflag.yaml         # default if present
    # baseline: .strayflag-baseline.json
    # fail-on: medium                 # low | medium | high | never
    # notes-out: build/notes-for-review.md
    # setup-dart: false               # if Flutter/Dart is already on PATH (e.g. after subosito/flutter-action)
```

The action builds the CLI from source with Dart (about 10 s), runs it, writes a markdown table to the
**job summary**, and fails the step on findings unless `fail-on: never`. Outputs: `result` (`pass`/`fail`),
`findings` (count), `report` (path to the JSON report). Works on `ubuntu-*` and `macos-*` runners.

`path` may be a glob, but it must match exactly one artifact.

## Limitations (please read)

- **Strings only.** strayflag finds suspicious *text* in the binary. It does no control-flow analysis, so
  it can't tell whether a flag is reachable, defaulted to off, or removed by tree shaking in a way that still
  leaves the string behind. A finding means "a human should look at this", not "this will be rejected".
- **Flags with harmless names are missed.** A switch called `x7` or one assembled at runtime won't be found.
  Compile-time constants (`bool.fromEnvironment('…')`, `#if DEBUG`) are usually folded away and leave no
  string. That's fine, because they're also gone from the build.
- **Name-based detection.** It finds what the denylist names. Add your own team's conventions under `deny:`.
- **Unity**: IL2CPP only (not Mono). The metadata parser understands the classic header layout (metadata v24–v31,
  Unity 2018 to Unity 6.0). For newer layouts it falls back to a generic `strings` scan of the file, which still
  works but can glue neighbouring literals together.
- **Encrypted / packed builds**: App Store–encrypted (FairPlay) binaries downloaded from a device can't be read.
  Scan the artifact you build, before upload. Assets (images, JSON, asset bundles) are not scanned.
- **No guarantee.** Passing this check does not mean your app will be approved. This project is not
  affiliated with or endorsed by Apple or Google. Guideline numbers are quoted for context; read the current
  [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) yourself.

## Development

```sh
dart pub get
dart test                         # unit + end-to-end tests on synthetic .ipa/.apk/.aab/.xcarchive fixtures
dart run tool/make_fixtures.dart  # writes demo artifacts to example/fixtures/
tool/build_real_flutter_fixture.sh /tmp/real   # real obfuscated Flutter release APK with planted flags
STRAYFLAG_REAL_APK=/tmp/real/planted_app/build/app/outputs/flutter-apk/app-release.apk dart test
```

## License

MIT © 2026 Arton Glocke / Amaranth Labs
