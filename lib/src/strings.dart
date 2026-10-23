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

/// Like `strings(1)` but UTF-8 aware: runs of printable ASCII and valid UTF-8
/// multi-byte characters (č, š, ž, —, …), so localized text is not cut at the
/// first non-ASCII character. A run must have at least [minLength] characters,
/// at least half of them ASCII, which keeps random binary data out.
Iterable<ExtractedString> textStrings(Uint8List bytes,
    {int minLength = 4, int start = 0, int? end, Uint8List? skip}) sync* {
  final stop = end ?? bytes.length;
  var runStart = -1;
  var chars = 0, ascii = 0;
  final buf = StringBuffer();

  ExtractedString? flush() {
    ExtractedString? out;
    if (runStart >= 0 && chars >= minLength && ascii * 2 >= chars) {
      out = ExtractedString(buf.toString(), runStart);
    }
    runStart = -1;
    chars = 0;
    ascii = 0;
    buf.clear();
    return out;
  }

  var i = start;
  while (i < stop) {
    if (skip != null && skip[i] != 0) {
      final o = flush();
      if (o != null) yield o;
      i++;
      continue;
    }
    final b = bytes[i];
    var cp = -1, n = 1;
    if (_printable(b)) {
      cp = b;
    } else if (b >= 0xC2 && b <= 0xF4) {
      n = b < 0xE0 ? 2 : (b < 0xF0 ? 3 : 4);
      if (i + n <= stop) {
        var v = b & (0xFF >> (n + 1));
        var ok = true;
        for (var k = 1; k < n; k++) {
          final c = bytes[i + k];
          if (c & 0xC0 != 0x80 || (skip != null && skip[i + k] != 0)) {
            ok = false;
            break;
          }
          v = (v << 6) | (c & 0x3F);
        }
        final minForLen = const [0, 0, 0x80, 0x800, 0x10000][n];
        if (ok && v >= minForLen && v >= 0xA0 && v <= 0x10FFFF && (v < 0xD800 || v > 0xDFFF) && v != 0xFEFF) {
          cp = v;
        }
      }
    }
    if (cp < 0) {
      final o = flush();
      if (o != null) yield o;
      i++;
      continue;
    }
    if (runStart < 0) runStart = i;
    buf.writeCharCode(cp);
    chars++;
    if (cp < 0x80) ascii++;
    i += n;
    if (chars >= maxStringLength) {
      final o = flush();
      if (o != null) yield o;
    }
  }
  final o = flush();
  if (o != null) yield o;
}

/// Whether a UTF-16 code unit can appear in real text (not a C0/C1 control,
/// not a non-character).
bool _textUnit(int u) =>
    (u >= 0x20 && u < 0x7F) || u == 0x09 || u == 0x0A || u == 0x0D || (u >= 0xA0 && u != 0xFFFE && u != 0xFFFF);

/// Reads the string table of a Dart AOT snapshot (`App.framework/App`,
/// `libapp.so`).
///
/// Dart writes each string as a variable-length length prefix
/// (`length << 1 | isTwoByte`, 7 bits per byte, low groups first, last byte
/// has the high bit set) followed by the characters: Latin-1 bytes for
/// one-byte strings, UTF-16LE for anything with characters above U+00FF
/// (Croatian č ć š ž đ, em dashes, emoji…). Reading the prefix gives exact
/// string boundaries even for non-ASCII text, and no stray length bytes.
///
/// Marks every byte that belongs to a decoded string in [covered] (if
/// given), so a generic scan can skip those regions.
List<ExtractedString> dartSnapshotStrings(Uint8List bytes, {int minLength = 4, Uint8List? covered}) {
  final out = <ExtractedString>[];
  var i = 0;
  final n = bytes.length;
  while (i < n) {
    final b = bytes[i];
    if (b < 0x80) {
      i++;
      continue;
    }
    // Try the prefix ending at i with 0, 1 or 2 preceding 7-bit groups.
    var accepted = false;
    for (var extra = 0; extra <= 2 && !accepted; extra++) {
      if (i - extra < 0) break;
      var v = b & 0x7F;
      var ok = true;
      for (var k = 1; k <= extra; k++) {
        final c = bytes[i - k];
        if (c >= 0x80) {
          ok = false;
          break;
        }
        v = (v << 7) | c;
      }
      if (!ok) continue;
      // The shortest encoding is always used.
      if (extra == 1 && v < 0x80) continue;
      if (extra == 2 && v < 0x4000) continue;
      final twoByte = v & 1 == 1;
      final len = v >> 1;
      if (len < minLength || len > 1 << 16) continue;
      final start = i + 1;
      final byteLen = twoByte ? len * 2 : len;
      if (start + byteLen > n) continue;
      final s = twoByte ? _twoByte(bytes, start, len) : _oneByte(bytes, start, len);
      if (s == null) continue;
      out.add(ExtractedString(s, start));
      if (covered != null) covered.fillRange(i - extra, start + byteLen, 1);
      i = start + byteLen;
      accepted = true;
    }
    if (!accepted) i++;
  }
  return out;
}

String? _oneByte(Uint8List b, int start, int len) {
  var ascii = 0;
  for (var k = start; k < start + len; k++) {
    final c = b[k];
    if (!_textUnit(c)) return null;
    if (c < 0x80) ascii++;
  }
  if (ascii * 2 < len) return null;
  return String.fromCharCodes(b, start, start + len);
}

String? _twoByte(Uint8List b, int start, int len) {
  // Validate before allocating: most candidates fail within a few units.
  var ascii = 0;
  var prevHigh = false;
  for (var k = 0; k < len; k++) {
    final u = b[start + 2 * k] | (b[start + 2 * k + 1] << 8);
    final high = u >= 0xD800 && u < 0xDC00;
    final low = u >= 0xDC00 && u <= 0xDFFF;
    if (low != prevHigh) return null; // surrogates must pair up
    if (!high && !low && !_textUnit(u)) return null;
    if (u < 0x80) ascii++;
    prevHigh = high;
  }
  if (prevHigh || ascii * 2 < len) return null;
  final units = Uint16List(len);
  for (var k = 0; k < len; k++) {
    units[k] = b[start + 2 * k] | (b[start + 2 * k + 1] << 8);
  }
  return String.fromCharCodes(units);
}

/// Reads the string table of an Android DEX file (exact boundaries, no stray
/// ULEB128 length byte in front). Returns null if the header is not usable.
List<ExtractedString>? dexStrings(Uint8List bytes) {
  if (bytes.length < 0x70 || bytes[0] != 0x64 || bytes[1] != 0x65 || bytes[2] != 0x78 || bytes[3] != 0x0A) {
    return null;
  }
  final bd = ByteData.sublistView(bytes);
  final count = bd.getUint32(0x38, Endian.little);
  final idsOff = bd.getUint32(0x3C, Endian.little);
  if (idsOff + count * 4 > bytes.length) return null;
  final out = <ExtractedString>[];
  for (var k = 0; k < count; k++) {
    var p = bd.getUint32(idsOff + 4 * k, Endian.little);
    if (p >= bytes.length) return null;
    // Skip the ULEB128 UTF-16 length.
    while (p < bytes.length && bytes[p] & 0x80 != 0) {
      p++;
    }
    p++;
    var e = p;
    while (e < bytes.length && bytes[e] != 0) {
      e++;
    }
    if (e - p < 4) continue;
    // MUTF-8 is UTF-8 apart from NUL and supplementary characters.
    out.add(ExtractedString(decodeUtf8(bytes, p, e), p));
  }
  return out;
}
