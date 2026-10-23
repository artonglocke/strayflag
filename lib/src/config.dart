import 'dart:io';

import 'package:yaml/yaml.dart';

import 'rules.dart';

/// Default config file names, looked up in the working directory.
const configFileNames = ['.strayflag.yaml', '.strayflag.yml', 'strayflag.yaml'];

/// A feature that is behind a flag on purpose and is declared to App Review.
class DeclaredFeature {
  DeclaredFeature({required this.name, required this.flags, this.description = '', this.howToEnable = ''});
  final String name;

  /// Strings that legitimately appear in the binary for this feature. Any
  /// finding containing one of these is reported as "declared", not as a
  /// problem.
  final List<String> flags;
  final String description;
  final String howToEnable;

  bool covers(String s) {
    final lower = s.toLowerCase();
    return flags.any((f) => lower.contains(f.toLowerCase()));
  }
}

/// An allowlist entry: plain text (case-insensitive substring) or `re:<regex>`.
class AllowEntry {
  AllowEntry(this.raw) : _regex = raw.startsWith('re:') ? RegExp(raw.substring(3)) : null;
  final String raw;
  final RegExp? _regex;
  bool matches(String s) => _regex != null ? _regex.hasMatch(s) : s.toLowerCase().contains(raw.toLowerCase());
}

class Config {
  Config({
    this.extraRules = const [],
    this.disabledTerms = const {},
    this.allow = const [],
    this.features = const [],
    this.expect = const [],
    this.failOnMissingExpected = false,
    this.failOn,
    this.minSeverity,
    this.notesIntro,
    this.path,
  });

  final List<Rule> extraRules;

  /// Built-in terms switched off with `disable:`.
  final Set<String> disabledTerms;
  final List<AllowEntry> allow;
  final List<DeclaredFeature> features;

  /// Strings that must be present (e.g. real product IDs). A missing one means
  /// the release build may be wired to mocks.
  final List<String> expect;
  final bool failOnMissingExpected;
  final Severity? failOn;
  final Severity? minSeverity;
  final String? notesIntro;
  final String? path;

  List<Rule> get rules => [
        for (final r in builtInRules)
          if (!disabledTerms.contains(r.term)) r,
        ...extraRules,
      ];

  static Config load(String? explicitPath) {
    String? path = explicitPath;
    if (path == null) {
      for (final n in configFileNames) {
        if (File(n).existsSync()) {
          path = n;
          break;
        }
      }
    }
    if (path == null) return Config();
    final f = File(path);
    if (!f.existsSync()) throw FormatException('Config file not found: $path');
    return parse(f.readAsStringSync(), path: path);
  }

  static Config parse(String text, {String? path}) {
    final doc = loadYaml(text, sourceUrl: path == null ? null : Uri.file(path));
    if (doc == null) return Config(path: path);
    if (doc is! YamlMap) throw FormatException('${path ?? 'config'}: top level must be a map');

    List<dynamic> list(String key) {
      final v = doc[key];
      if (v == null) return const [];
      if (v is! YamlList) throw FormatException('${path ?? 'config'}: "$key" must be a list');
      return v.toList();
    }

    String str(Object? v, String what) {
      if (v == null) throw FormatException('${path ?? 'config'}: missing $what');
      return v.toString();
    }

    final extra = <Rule>[];
    for (final d in list('deny')) {
      if (d is YamlMap) {
        extra.add(Rule(str(d['term'], 'deny[].term'), Severity.parse((d['severity'] ?? 'medium').toString()),
            (d['category'] ?? 'custom').toString(),
            builtIn: false));
      } else {
        extra.add(Rule(d.toString(), Severity.medium, 'custom', builtIn: false));
      }
    }

    final features = <DeclaredFeature>[];
    for (final f in list('features')) {
      if (f is! YamlMap) throw FormatException('${path ?? 'config'}: each feature must be a map');
      final flags = f['flags'] ?? f['flag'];
      features.add(DeclaredFeature(
        name: str(f['name'], 'features[].name'),
        flags: flags == null
            ? const []
            : flags is YamlList
                ? [for (final x in flags) x.toString()]
                : [flags.toString()],
        description: (f['description'] ?? '').toString().trim(),
        howToEnable: (f['how_to_enable'] ?? f['howToEnable'] ?? '').toString().trim(),
      ));
    }

    return Config(
      extraRules: extra,
      disabledTerms: {for (final d in list('disable')) d.toString()},
      allow: [for (final a in list('allow')) AllowEntry(a.toString())],
      features: features,
      expect: [for (final e in list('expect')) e.toString()],
      failOnMissingExpected: doc['fail_on_missing_expected'] == true,
      failOn: doc['fail_on'] == null ? null : Severity.parse(doc['fail_on'].toString()),
      minSeverity: doc['min_severity'] == null ? null : Severity.parse(doc['min_severity'].toString()),
      notesIntro: doc['notes_intro']?.toString().trim(),
      path: path,
    );
  }
}

const sampleConfig = '''
# strayflag configuration. All keys are optional.

# Lowest severity that makes the scan fail (exit code 1): low | medium | high
fail_on: medium
# Lowest severity shown in the report (default: medium)
min_severity: medium

# Extra terms to flag. Plain strings are medium severity.
deny:
  - qa build
  - term: free coins
    severity: high

# Built-in terms you never want to hear about.
disable:
  - localhost

# Known false positives. Case-insensitive substring, or re:<regex>.
allow:
  - "Debug output"
  - "re:^https://staging-docs\\\\.example\\\\.com"

# Features that ARE behind a flag on purpose. Matching strings are reported
# as "declared" instead of failing the build, and are written into the
# generated Notes for Review section.
features:
  - name: Screenshot mode
    flags: [screenshots-mode]
    description: Fills the app with sample data for App Store screenshots. No purchases are unlocked.
    how_to_enable: Not reachable by users. Only enabled by our UI test runner via a launch argument.

# Strings that must exist in a real release (product IDs, purchase classes).
# If one is missing the build may be wired to mocks.
expect:
  - com.example.app.pro_monthly
fail_on_missing_expected: false

# Optional first paragraph of the generated Notes for Review.
# notes_intro: "Demo account: reviewer@example.com / see App Review Information."
''';
