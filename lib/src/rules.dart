/// How serious a match is. Findings at or above the `fail_on` level make the
/// scan exit with code 1.
enum Severity {
  low,
  medium,
  high;

  static Severity parse(String s) => switch (s.trim().toLowerCase()) {
        'low' => Severity.low,
        'medium' || 'med' => Severity.medium,
        'high' => Severity.high,
        _ => throw FormatException('Unknown severity "$s" (use low, medium or high)'),
      };
}

/// One denylist term.
class Rule {
  Rule(this.term, this.severity, this.category, {this.builtIn = true})
      : tokens = tokenize(term),
        joined = tokenize(term).join(),
        pattern = null;

  /// A rule matched by regular expression against the raw string, for things
  /// word matching cannot express (e.g. non-production hostnames in URLs).
  Rule.pattern(this.term, RegExp this.pattern, this.severity, this.category, {this.builtIn = true})
      : tokens = const [],
        joined = '';

  final RegExp? pattern;

  final String term;
  final Severity severity;
  final String category;
  final bool builtIn;
  final List<String> tokens;

  /// All tokens glued together, to catch `devmenu`, `TESTMODE`, `unlockall`.
  final String joined;

  @override
  String toString() => term;
}

final _boundary = RegExp(r'[^A-Za-z0-9]+');
final _lowerUpper = RegExp(r'([a-z0-9])([A-Z])');
final _acronym = RegExp(r'([A-Z]+)([A-Z][a-z])');
final _letterDigit = RegExp(r'([A-Za-z])([0-9])');
final _digitLetter = RegExp(r'([0-9])([A-Za-z])');

/// Splits an identifier or phrase into lowercase words, aware of camelCase,
/// PascalCase, snake_case, kebab-case, dotted.names and ACRONYMWords.
///
/// `enableUnlockedMockPurchases` -> [enable, unlocked, mock, purchases]
/// `IAPBypass_v2` -> [iap, bypass, v, 2]
List<String> tokenize(String s) {
  var t = s.replaceAllMapped(_acronym, (m) => '${m[1]} ${m[2]}');
  t = t.replaceAllMapped(_lowerUpper, (m) => '${m[1]} ${m[2]}');
  t = t.replaceAllMapped(_letterDigit, (m) => '${m[1]} ${m[2]}');
  t = t.replaceAllMapped(_digitLetter, (m) => '${m[1]} ${m[2]}');
  return [
    for (final w in t.split(_boundary))
      if (w.isNotEmpty) w.toLowerCase(),
  ];
}

/// True if [word] is [term] or a simple inflection of it
/// (mock/mocks/mocked/mocking, purchase/purchases/purchased).
bool wordMatches(String word, String term) {
  if (word == term) return true;
  if (!word.startsWith(term)) {
    // purchase -> purchasing
    return term.endsWith('e') && word == '${term.substring(0, term.length - 1)}ing';
  }
  final rest = word.substring(term.length);
  return const {'s', 'es', 'd', 'ed', 'ing', 'ged', 'ging'}.contains(rest);
}

/// Returns true if [rule] occurs in the token list [words] on word
/// boundaries, either as consecutive words or glued into one word.
bool ruleMatches(Rule rule, List<String> words, [String? raw]) {
  if (rule.pattern != null) return raw != null && rule.pattern!.hasMatch(raw);
  final n = rule.tokens.length;
  if (n == 0) return false;
  for (var i = 0; i < words.length; i++) {
    if (n > 1 && wordMatches(words[i], rule.joined)) return true;
    if (i + n > words.length) continue;
    var ok = true;
    for (var k = 0; k < n; k++) {
      if (!wordMatches(words[i + k], rule.tokens[k])) {
        ok = false;
        break;
      }
    }
    if (ok) return true;
  }
  return false;
}

Rule _h(String t, String c) => Rule(t, Severity.high, c);
Rule _m(String t, String c) => Rule(t, Severity.medium, c);
Rule _l(String t, String c) => Rule(t, Severity.low, c);

/// Built-in denylist. High = would unlock paid content or hide functionality
/// outright. Medium = test / debug switches a reviewer should not stumble on.
/// Low = generic words that are mostly noise in framework code; hidden from the
/// report unless `--min-severity low` is set.
final List<Rule> builtInRules = [
  // Purchases and entitlements
  for (final t in [
    'mock purchase',
    'fake purchase',
    'test purchase',
    'debug purchase',
    'unlocked mock',
    'mock entitlement',
    'fake entitlement',
    'entitlement override',
    'override entitlement',
    'mock receipt',
    'fake receipt',
    'mock subscription',
    'fake subscription',
    'premium override',
    'override premium',
    'force premium',
    'grant premium',
    'free premium',
    'unlock premium',
    'unlock all',
    'unlock everything',
    'all unlocked',
    'unlock pro',
    'force pro',
    'bypass paywall',
    'paywall bypass',
    'skip paywall',
    'disable paywall',
    'hide paywall',
    'bypass purchase',
    'purchase bypass',
    'iap bypass',
    'bypass iap',
    'free iap',
    'is premium override',
    'fake pro',
    'mock pro',
  ])
    _h(t, 'purchases'),
  // Cheats and hidden menus
  for (final t in [
    'god mode',
    'cheat menu',
    'cheat code',
    'cheats enabled',
    'enable cheats',
    'backdoor',
    'secret menu',
    'hidden menu'
  ])
    _h(t, 'hidden'),
  for (final t in [
    'dev menu',
    'developer menu',
    'debug menu',
    'debug panel',
    'debug screen',
    'debug drawer',
    'debug overlay',
    'debug settings',
    'qa menu',
    'qa panel',
    'qa mode',
    'test menu',
    'admin menu',
    'internal menu',
    'dev tools menu',
    'dev panel',
    'dev settings',
    'feature flag override',
    'flag override',
    'override flags',
    'cheat',
    'cheats',
  ])
    _m(t, 'debug-ui'),
  // Modes
  for (final t in [
    'screenshot mode',
    'screenshots mode',
    'demo mode',
    'test mode',
    'testing mode',
    'mock mode',
    'debug mode',
    'dev mode',
    'sandbox mode',
    'review mode',
    'marketing mode',
    'slow entitlement',
    'fake data',
    'mock data',
    'mock server',
    'mock api',
    'mock backend',
    'fake backend',
    'mock user',
    'fake user',
    'mock login',
    'fake login',
    'skip login',
    'bypass login',
    'skip auth',
    'bypass auth',
    'disable auth',
    'skip onboarding',
    'skip verification',
    'bypass verification',
  ])
    _m(t, 'test-mode'),
  // Environments
  for (final t in [
    'staging api',
    'staging server',
    'staging url',
    'staging env',
    'staging environment',
    'staging backend',
    'use staging',
    'stage api',
    'dev api',
    'dev server',
    'test server',
    'qa server',
    'ngrok',
  ])
    _m(t, 'environment'),
  Rule.pattern(
    'non-production URL',
    RegExp(r'(https?|wss?)://([a-z0-9-]+[.-])*(staging|stage|stg|dev|qa|uat|test|sandbox)[0-9]*[.-]',
        caseSensitive: false),
    Severity.medium,
    'environment',
  ),
  Rule.pattern(
      'ngrok tunnel', RegExp(r'\.ngrok(-free)?\.(io|app|dev)\b', caseSensitive: false), Severity.medium, 'environment'),
  // Generic words: mostly framework noise, shown only with --min-severity low
  for (final t in [
    'debug',
    'mock',
    'mocked',
    'fake',
    'dummy',
    'test',
    'testing',
    'qa',
    'dev',
    'sandbox',
    'unlocked',
    'override',
    'premium',
    'hidden',
    'secret',
    'bypass',
    'localhost'
  ])
    _l(t, 'generic'),
];
