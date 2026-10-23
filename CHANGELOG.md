## 0.1.0

- First release: scans `.ipa`, `.xcarchive`, `.app`, `.apk`, `.aab` and raw binaries.
- Flutter (Dart AOT snapshot), Unity IL2CPP (`global-metadata.dat` literal table), React Native bundles, native fallback.
- Built-in denylist with camelCase/snake_case aware word matching and three severities.
- `.strayflag.yaml`: extra terms, allowlist, declared flag-gated features, expected strings.
- Baseline diff against a previous JSON report or previous build.
- Text, JSON, job-summary markdown and Notes for Review output; exit codes 0/1/2.
- Composite GitHub Action.
