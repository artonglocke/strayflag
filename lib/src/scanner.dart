import 'dart:typed_data';

import 'artifact.dart';
import 'config.dart';
import 'detect.dart';
import 'il2cpp.dart';
import 'rules.dart';
import 'strings.dart';

/// One suspicious string found in a scanned file.
class Finding {
  Finding({
    required this.value,
    required this.file,
    required this.offset,
    required this.rules,
    this.count = 1,
    this.declaredAs,
    this.source = 'string',
  });

  final String value;
  final String file;
  final int offset;
  int count;

  /// All rules that matched; the first is the most severe.
  final List<Rule> rules;

  /// Name of the declared feature that covers this string, if any.
  final String? declaredAs;

  /// `literal`, `identifier` or `string` (generic scan).
  final String source;

  Severity get severity => rules.first.severity;

  /// Matched terms worth showing: generic low-severity words are dropped
  /// when a more specific term also matched.
  List<String> get terms => [
        for (final r in rules)
          if (r.severity == severity || r.severity != Severity.low) r.term,
      ];
  bool get declared => declaredAs != null;

  Map<String, Object?> toJson() => {
        'string': value,
        'severity': severity.name,
        'terms': terms,
        'category': rules.first.category,
        'file': file,
        'offset': offset,
        'count': count,
        'source': source,
        if (declaredAs != null) 'declared_feature': declaredAs,
      };
}

class TargetSummary {
  TargetSummary(this.path, this.kind, this.reason, this.size, this.stringCount, {this.note});
  final String path;
  final TargetKind kind;
  final String reason;
  final int size;
  final int stringCount;
  final String? note;
}

class ScanResult {
  ScanResult({
    required this.artifact,
    required this.detection,
    required this.targets,
    required this.findings,
    required this.declared,
    required this.allowed,
    required this.missingExpected,
    required this.unseenDeclaredFeatures,
    required this.allStrings,
    this.baselineSuppressed = const [],
  });

  final String artifact;
  final Detection detection;
  final List<TargetSummary> targets;

  /// Undeclared findings (any severity), sorted most severe first.
  final List<Finding> findings;
  final List<Finding> declared;
  final int allowed;
  final List<String> missingExpected;

  /// Declared features none of whose flags were seen in this build.
  final List<String> unseenDeclaredFeatures;

  /// Every suspicious string value, before baseline filtering. Used to write
  /// a baseline.
  final Set<String> allStrings;

  /// Findings hidden because they were already in the baseline.
  final List<Finding> baselineSuppressed;
}

class Scanner {
  Scanner(this.config) : rules = _sorted(config.rules);
  final Config config;
  final List<Rule> rules;

  static List<Rule> _sorted(List<Rule> r) => [...r]..sort((a, b) => b.severity.index.compareTo(a.severity.index));

  /// Rules that match [s], most severe first. Empty if none.
  List<Rule> match(String s) {
    final words = tokenize(s);
    if (words.isEmpty) return const [];
    return [
      for (final r in rules)
        if (ruleMatches(r, words, s)) r,
    ];
  }

  ScanResult scanPath(String path, {bool deep = false, Set<String>? baseline}) {
    final artifact = Artifact.open(path);
    try {
      return scan(artifact, deep: deep, baseline: baseline);
    } finally {
      artifact.close();
    }
  }

  ScanResult scan(Artifact artifact, {bool deep = false, Set<String>? baseline}) {
    final detection = detect(artifact, deep: deep);
    if (detection.targets.isEmpty) {
      throw ArtifactException('Found nothing to scan in ${artifact.source} '
          '(no Flutter, Unity, React Native or native binary detected).');
    }

    final byKey = <String, Finding>{};
    final summaries = <TargetSummary>[];
    final expectLeft = {...config.expect};
    final featuresSeen = <String>{};
    var allowed = 0;

    for (final t in detection.targets) {
      final bytes = t.entry.read();
      final extracted = _extract(t, bytes);
      summaries
          .add(TargetSummary(t.path, t.kind, t.reason, bytes.length, extracted.strings.length, note: extracted.note));

      for (final (es, source) in extracted.strings) {
        if (expectLeft.isNotEmpty) expectLeft.removeWhere((x) => es.value.contains(x));
        final matched = match(es.value);
        if (matched.isEmpty) continue;
        if (config.allow.any((a) => a.matches(es.value))) {
          allowed++;
          continue;
        }
        DeclaredFeature? feature;
        for (final f in config.features) {
          if (f.covers(es.value)) {
            feature = f;
            featuresSeen.add(f.name);
            break;
          }
        }
        final key = '${t.path}\u0000${es.value}';
        final existing = byKey[key];
        if (existing != null) {
          existing.count++;
        } else {
          byKey[key] = Finding(
            value: es.value,
            file: t.path,
            offset: es.offset,
            rules: matched,
            declaredAs: feature?.name,
            source: source,
          );
        }
      }
    }

    final order = {for (var i = 0; i < summaries.length; i++) summaries[i].path: i};
    final all = byKey.values.toList()
      ..sort((a, b) {
        final f = order[a.file]!.compareTo(order[b.file]!);
        if (f != 0) return f;
        final s = b.severity.index.compareTo(a.severity.index);
        return s != 0 ? s : a.value.compareTo(b.value);
      });
    final allStrings = {for (final f in all) f.value};
    final suppressed = <Finding>[];
    final findings = <Finding>[];
    final declared = <Finding>[];
    for (final f in all) {
      if (f.declared) {
        declared.add(f);
      } else if (baseline != null && baseline.contains(f.value)) {
        suppressed.add(f);
      } else {
        findings.add(f);
      }
    }
    return ScanResult(
      artifact: artifact.source,
      detection: detection,
      targets: summaries,
      findings: findings,
      declared: declared,
      allowed: allowed,
      missingExpected: [
        for (final e in config.expect)
          if (expectLeft.contains(e)) e
      ],
      unseenDeclaredFeatures: [
        for (final f in config.features)
          if (f.flags.isNotEmpty && !featuresSeen.contains(f.name)) f.name,
      ],
      allStrings: allStrings,
      baselineSuppressed: suppressed,
    );
  }

  _Extracted _extract(ScanTarget t, Uint8List bytes) {
    switch (t.kind) {
      case TargetKind.il2cppMetadata:
        final m = readIl2CppMetadata(bytes);
        return _Extracted(
          [
            for (final s in m.literals) (s, 'literal'),
            for (final s in m.identifiers) (s, m.parsed ? 'identifier' : 'string'),
          ],
          m.parsed
              ? 'metadata v${m.version}: ${m.literals.length} literals, ${m.identifiers.length} names'
              : 'metadata v${m.version} layout not recognised, used generic strings scan',
        );
      case TargetKind.dartAot:
      case TargetKind.binary:
      case TargetKind.jsBundle:
        // Dart keeps most literals as one-byte (Latin-1) strings; strings with
        // non-Latin-1 characters are two-byte, so scan UTF-16LE as well.
        final out = <(ExtractedString, String)>[
          for (final s in asciiStrings(bytes)) (s, 'string'),
        ];
        final seen = {for (final (s, _) in out) s.value};
        for (final s in utf16leStrings(bytes, minLength: 6)) {
          if (seen.add(s.value)) out.add((s, 'utf16'));
        }
        return _Extracted(out, null);
    }
  }
}

class _Extracted {
  _Extracted(this.strings, this.note);
  final List<(ExtractedString, String)> strings;
  final String? note;
}
