## 0.1.0

- First release: scans `.ipa`, `.xcarchive`, `.app`, `.apk`, `.aab` and raw binaries.
- Flutter (Dart AOT snapshot), Unity IL2CPP (`global-metadata.dat` literal table), React Native bundles, native fallback.
- Built-in denylist with camelCase/snake_case aware word matching and three severities.
- `.strayflag.yaml`: extra terms, allowlist, declared flag-gated features, expected strings.
- Baseline diff against a previous JSON report or previous build.
- Text, JSON, job-summary markdown and Notes for Review output; exit codes 0/1/2.
- Composite GitHub Action.
- Exact string extraction from the Dart AOT string table (Latin-1 + UTF-16) and the DEX string table, plus a
  UTF-8-aware generic scan, so non-ASCII text (č ć š ž đ, em dashes, emoji) is never cut and DEX strings have no
  stray length byte. Custom deny terms may contain non-ASCII letters.
