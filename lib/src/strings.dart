import 'dart:convert';
import 'dart:typed_data';

/// A string pulled out of a binary, with the byte offset of its first byte.
class ExtractedString {
  const ExtractedString(this.value, this.offset);
  final String value;
  final int offset;
  @override
  String toString() => '$offset:$value';
}

/// Longest string kept in one piece. Longer printable runs are split, so a
/// blob of concatenated text does not turn into one giant "string".
const int maxStringLength = 512;

bool _printable(int b) => (b >= 0x20 && b <= 0x7e) || b == 0x09;

/// Like `strings(1)`: runs of at least [minLength] printable ASCII bytes.
Iterable<ExtractedString> asciiStrings(Uint8List bytes, {int minLength = 4, int start = 0, int? end}) sync* {
  final stop = end ?? bytes.length;
  var runStart = -1;
  for (var i = start; i <= stop; i++) {
    final ok = i < stop && _printable(bytes[i]);
    if (ok) {
      if (runStart < 0) runStart = i;
      if (i - runStart + 1 >= maxStringLength) {
        yield ExtractedString(String.fromCharCodes(bytes, runStart, i + 1), runStart);
        runStart = -1;
      }
    } else if (runStart >= 0) {
      if (i - runStart >= minLength) {
        yield ExtractedString(String.fromCharCodes(bytes, runStart, i), runStart);
      }
      runStart = -1;
    }
  }
}

/// Runs of printable ASCII encoded as UTF-16LE (each char followed by 0x00).
/// Dart and .NET store some strings this way.
Iterable<ExtractedString> utf16leStrings(Uint8List bytes, {int minLength = 4}) sync* {
  for (final align in const [0, 1]) {
    var runStart = -1;
    final codes = <int>[];
    for (var i = align; i + 1 <= bytes.length; i += 2) {
      final ok = i + 1 < bytes.length && _printable(bytes[i]) && bytes[i + 1] == 0;
      if (ok) {
        if (runStart < 0) runStart = i;
        codes.add(bytes[i]);
        if (codes.length >= maxStringLength) {
          yield ExtractedString(String.fromCharCodes(codes), runStart);
          codes.clear();
          runStart = -1;
        }
      } else if (runStart >= 0) {
        if (codes.length >= minLength) {
          yield ExtractedString(String.fromCharCodes(codes), runStart);
        }
        codes.clear();
        runStart = -1;
      }
    }
  }
}

/// Decodes UTF-8 leniently, used for IL2CPP string literals.
String decodeUtf8(Uint8List bytes, int start, int end) =>
    utf8.decode(Uint8List.sublistView(bytes, start, end), allowMalformed: true);
