import 'dart:convert';
import 'dart:io';

import 'config.dart';
import 'detect.dart';
import 'rules.dart';
import 'scanner.dart';

const toolVersion = '0.1.0';

String _fw(Framework f) => switch (f) {
      Framework.flutter => 'Flutter',
      Framework.unity => 'Unity (IL2CPP)',
      Framework.reactNative => 'React Native',
      Framework.native => 'native',
    };

String _clip(String s, [int max = 100]) {
  final one = s.replaceAll(RegExp(r'\s+'), ' ');
  return one.length <= max ? one : '${one.substring(0, max - 1)}…';
}

String _size(int b) => b >= 1 << 20
    ? '${(b / (1 << 20)).toStringAsFixed(1)} MB'
    : b >= 1024
        ? '${(b / 1024).toStringAsFixed(1)} KB'
        : '$b B';

class ReportOptions {
  ReportOptions(
      {required this.minSeverity, required this.failOn, this.color = false, this.failOnMissingExpected = false});
  final Severity minSeverity;
  final Severity? failOn; // null = never fail on findings
  final bool color;
  final bool failOnMissingExpected;
}

List<Finding> visible(ScanResult r, ReportOptions o) => [
      for (final f in r.findings)
        if (f.severity.index >= o.minSeverity.index) f
    ];

int suppressedVisible(ScanResult r, ReportOptions o) =>
    r.baselineSuppressed.where((f) => f.severity.index >= o.minSeverity.index).length;

bool failed(ScanResult r, ReportOptions o) =>
    (o.failOn != null && r.findings.any((f) => f.severity.index >= o.failOn!.index)) ||
    (o.failOnMissingExpected && r.missingExpected.isNotEmpty);

/// Human-readable terminal report.
String textReport(ScanResult r, ReportOptions o) {
  String c(String code, String s) => o.color ? '\x1B[${code}m$s\x1B[0m' : s;
  String sev(Severity s) => switch (s) {
        Severity.high => c('1;31', 'HIGH  '),
        Severity.medium => c('33', 'MEDIUM'),
        Severity.low => c('2', 'LOW   '),
      };
  final b = StringBuffer();
  final shown = visible(r, o);
  b.writeln("${c('1', 'strayflag $toolVersion')}  ${r.artifact}");
  b.writeln('Platform: ${r.detection.platform.name}   Framework: ${r.detection.frameworks.map(_fw).join(' + ')}');
  b.writeln('Scanned:');
  for (final t in r.targets) {
    b.writeln(
        '  • ${t.path}  (${t.reason}, ${_size(t.size)}, ${t.stringCount} strings${t.note == null ? '' : '; ${t.note}'})');
  }
  b.writeln();

  if (shown.isEmpty) {
    b.writeln(c('32', '✓ No suspicious strings at ${o.minSeverity.name} severity or above.'));
  } else {
    b.writeln(c('1', 'Suspicious strings (${shown.length}):'));
    String? lastFile;
    for (final f in shown) {
      if (r.targets.length > 1 && f.file != lastFile) {
        b.writeln('  ${c('2', f.file)}');
        lastFile = f.file;
      }
      final extra = f.count > 1 ? c('2', ' ×${f.count}') : '';
      b.writeln('  ${sev(f.severity)}  "${_clip(f.value)}"$extra');
      b.writeln(
          c('2', '          matched: ${f.terms.take(4).join(', ')}  [${f.source} @0x${f.offset.toRadixString(16)}]'));
    }
  }
  final hidden = r.findings.length - shown.length;
  if (hidden > 0) {
    final es = hidden == 1 ? '' : 'es';
    b.writeln(c('2', '  ($hidden lower-severity match$es hidden; use --min-severity low to see them)'));
  }
  final inBase = suppressedVisible(r, o);
  if (inBase > 0) b.writeln(c('2', '  ($inBase already in baseline, not shown)'));
  if (r.allowed > 0) b.writeln(c('2', '  (${r.allowed} allowlisted)'));

  if (r.declared.isNotEmpty) {
    b.writeln();
    b.writeln(c('1',
        'Declared flag-gated features found in build (${r.declared.length} string${r.declared.length == 1 ? '' : 's'}):'));
    final byFeature = <String, List<Finding>>{};
    for (final f in r.declared) {
      byFeature.putIfAbsent(f.declaredAs!, () => []).add(f);
    }
    byFeature.forEach((name, fs) {
      b.writeln('  ✓ $name: ${fs.map((f) => '"${_clip(f.value, 50)}"').take(5).join(', ')}');
    });
  }
  if (r.unseenDeclaredFeatures.isNotEmpty) {
    b.writeln();
    b.writeln(c('2', 'Declared features whose flags were not found in this build (still listed in Notes for Review):'));
    for (final n in r.unseenDeclaredFeatures) {
      b.writeln(c('2', '  - $n'));
    }
  }
  if (r.missingExpected.isNotEmpty) {
    b.writeln();
    b.writeln(c('33', '⚠ Expected strings missing from the build (is it wired to real purchases?):'));
    for (final e in r.missingExpected) {
      b.writeln('  - $e');
    }
  }

  b.writeln();
  if (failed(r, o)) {
    b.writeln('${c('1;31', '✗ FAIL')}'
        ' — remove these switches from release builds, add true false positives to `allow:`, '
        'or declare intentional ones under `features:` so they go into Notes for Review.');
  } else {
    b.writeln(c('1;32', '✓ PASS'));
  }
  return b.toString();
}

Map<String, Object?> jsonReport(ScanResult r, ReportOptions o) => {
      'tool': 'strayflag',
      'version': toolVersion,
      'artifact': r.artifact,
      'platform': r.detection.platform.name,
      'frameworks': [for (final f in r.detection.frameworks) f.name],
      'targets': [
        for (final t in r.targets)
          {
            'path': t.path,
            'kind': t.kind.name,
            'bytes': t.size,
            'strings': t.stringCount,
            if (t.note != null) 'note': t.note
          },
      ],
      'result': failed(r, o) ? 'fail' : 'pass',
      'fail_on': o.failOn?.name ?? 'never',
      'min_severity': o.minSeverity.name,
      'finding_count': visible(r, o).length,
      'findings': [for (final f in visible(r, o)) f.toJson()],
      'hidden_low_severity': r.findings.length - visible(r, o).length,
      'declared': [for (final f in r.declared) f.toJson()],
      'baseline_suppressed': suppressedVisible(r, o),
      'allowlisted': r.allowed,
      'missing_expected': r.missingExpected,
      'unseen_declared_features': r.unseenDeclaredFeatures,
      // Every suspicious string at any severity; lets this file act as a baseline.
      'baseline': (r.allStrings.toList()..sort()),
    };

String jsonText(ScanResult r, ReportOptions o) => const JsonEncoder.withIndent('  ').convert(jsonReport(r, o));

String _mdEscape(String s) => _clip(s, 120).replaceAll('|', r'\|').replaceAll('`', 'ˋ');

/// GitHub-flavoured markdown for `$GITHUB_STEP_SUMMARY` or PR comments.
String markdownSummary(ScanResult r, ReportOptions o) {
  final shown = visible(r, o);
  final b = StringBuffer();
  final pass = !failed(r, o);
  b.writeln(
      '### ${pass ? '✅' : '❌'} strayflag: ${pass ? 'no undeclared test switches' : '${shown.length} suspicious string${shown.length == 1 ? '' : 's'}'}');
  b.writeln();
  b.writeln('`${r.artifact}` · ${r.detection.platform.name} · ${r.detection.frameworks.map(_fw).join(' + ')} · '
      'scanned ${r.targets.map((t) => '`${t.path.split('/').last}`').join(', ')}');
  b.writeln();
  if (shown.isNotEmpty) {
    b.writeln('| Severity | String | Matched | File |');
    b.writeln('|---|---|---|---|');
    for (final f in shown) {
      b.writeln(
          '| ${f.severity.name} | `${_mdEscape(f.value)}` | ${f.terms.take(3).join(', ')} | `${f.file.split('/').last}` |');
    }
    b.writeln();
  }
  if (r.declared.isNotEmpty) {
    final names = {for (final f in r.declared) f.declaredAs!};
    b.writeln('Declared features present: ${names.join(', ')}.');
    b.writeln();
  }
  if (r.missingExpected.isNotEmpty) {
    b.writeln('⚠️ Expected strings missing: ${r.missingExpected.map((e) => '`$e`').join(', ')}');
    b.writeln();
  }
  final inBase = suppressedVisible(r, o);
  if (inBase > 0) b.writeln('_$inBase findings already in the baseline were not shown._');
  return b.toString();
}

/// "Notes for Review" text to paste into App Store Connect.
String notesForReview(Config config, {ScanResult? result}) {
  final b = StringBuffer();
  b.writeln('## Notes for Review');
  b.writeln();
  if (config.notesIntro != null && config.notesIntro!.isNotEmpty) {
    b.writeln(config.notesIntro);
    b.writeln();
  }
  if (config.features.isEmpty) {
    b.writeln('This build contains no features that are hidden behind flags, remote configuration or '
        'special launch conditions. All functionality is reachable through the normal user interface.');
    return b.toString();
  }
  b.writeln('This build contains the following feature${config.features.length == 1 ? '' : 's'} that '
      '${config.features.length == 1 ? 'is' : 'are'} controlled by a flag or not visible on first launch. '
      'Each is described below with the steps to reach it.');
  b.writeln();
  var i = 1;
  for (final f in config.features) {
    b.writeln('${i++}. **${f.name}**');
    if (f.description.isNotEmpty) b.writeln('   - What it does: ${f.description}');
    b.writeln(
        '   - How to enable it: ${f.howToEnable.isNotEmpty ? f.howToEnable : '(describe how a reviewer can reach this feature)'}');
    if (result != null && f.flags.isNotEmpty) {
      final present = result.declared.any((d) => d.declaredAs == f.name);
      if (!present) b.writeln('   - Status: not active in this build.');
    }
  }
  return b.toString();
}

void writeFile(String path, String content, {bool append = false}) {
  final f = File(path);
  f.parent.createSync(recursive: true);
  f.writeAsStringSync(content, mode: append ? FileMode.append : FileMode.write);
}
