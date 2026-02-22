// lib/utils/arabic_reshaper.dart
//
// Arabic text reshaper for PDF rendering without external dependency.
// This covers common Arabic letters and lam-alef ligatures.

class ArabicReshaper {
  ArabicReshaper._();
  static final ArabicReshaper instance = ArabicReshaper._();

  String reshape(String input) {
    if (input.isEmpty) return input;

    final codeUnits = input.runes.toList();
    final buffer = <int>[];

    for (var i = 0; i < codeUnits.length; i++) {
      final ch = codeUnits[i];

      if (_isTransparent(ch)) {
        buffer.add(ch);
        continue;
      }

      final current = _forms[ch];
      if (current == null) {
        buffer.add(ch);
        continue;
      }

      // Lam-Alef ligatures
      if (ch == _lam && i + 1 < codeUnits.length) {
        final next = codeUnits[i + 1];
        final ligature = _lamAlefLigatures[next];
        if (ligature != null) {
          final prevIndex = _prevLetterIndex(codeUnits, i);
          final prev = prevIndex == null ? null : codeUnits[prevIndex];
          final canConnectPrev =
              prev != null && _canConnectNext(prev) && _canConnectPrev(ch);
          buffer.add(canConnectPrev ? ligature.finalForm : ligature.isolatedForm);
          i++; // skip next (alef variant)
          continue;
        }
      }

      final prevIndex = _prevLetterIndex(codeUnits, i);
      final nextIndex = _nextLetterIndex(codeUnits, i);
      final prev = prevIndex == null ? null : codeUnits[prevIndex];
      final next = nextIndex == null ? null : codeUnits[nextIndex];

      final canConnectPrev =
          prev != null && _canConnectNext(prev) && _canConnectPrev(ch);
      final canConnectNext =
          next != null && _canConnectPrev(next) && _canConnectNext(ch);

      if (canConnectPrev && canConnectNext) {
        buffer.add(current.medial);
      } else if (canConnectPrev && !canConnectNext) {
        buffer.add(current.finalForm);
      } else if (!canConnectPrev && canConnectNext) {
        buffer.add(current.initial);
      } else {
        buffer.add(current.isolated);
      }
    }

    return String.fromCharCodes(buffer);
  }
}

class _Forms {
  final int isolated;
  final int finalForm;
  final int initial;
  final int medial;
  const _Forms(this.isolated, this.finalForm, this.initial, this.medial);
}

class _Ligature {
  final int isolatedForm;
  final int finalForm;
  const _Ligature(this.isolatedForm, this.finalForm);
}

const int _lam = 0x0644;

// Arabic letter forms map (base -> isolated, final, initial, medial)
const Map<int, _Forms> _forms = {
  0x0621: _Forms(0xFE80, 0xFE80, 0xFE80, 0xFE80), // HAMZA
  0x0622: _Forms(0xFE81, 0xFE82, 0xFE81, 0xFE82), // ALEF MADDA
  0x0623: _Forms(0xFE83, 0xFE84, 0xFE83, 0xFE84), // ALEF HAMZA ABOVE
  0x0624: _Forms(0xFE85, 0xFE86, 0xFE85, 0xFE86), // WAW HAMZA
  0x0625: _Forms(0xFE87, 0xFE88, 0xFE87, 0xFE88), // ALEF HAMZA BELOW
  0x0626: _Forms(0xFE89, 0xFE8A, 0xFE8B, 0xFE8C), // YEH HAMZA
  0x0627: _Forms(0xFE8D, 0xFE8E, 0xFE8D, 0xFE8E), // ALEF
  0x0628: _Forms(0xFE8F, 0xFE90, 0xFE91, 0xFE92), // BEH
  0x0629: _Forms(0xFE93, 0xFE94, 0xFE93, 0xFE94), // TEH MARBUTA
  0x062A: _Forms(0xFE95, 0xFE96, 0xFE97, 0xFE98), // TEH
  0x062B: _Forms(0xFE99, 0xFE9A, 0xFE9B, 0xFE9C), // THEH
  0x062C: _Forms(0xFE9D, 0xFE9E, 0xFE9F, 0xFEA0), // JEEM
  0x062D: _Forms(0xFEA1, 0xFEA2, 0xFEA3, 0xFEA4), // HAH
  0x062E: _Forms(0xFEA5, 0xFEA6, 0xFEA7, 0xFEA8), // KHAH
  0x062F: _Forms(0xFEA9, 0xFEAA, 0xFEA9, 0xFEAA), // DAL
  0x0630: _Forms(0xFEAB, 0xFEAC, 0xFEAB, 0xFEAC), // THAL
  0x0631: _Forms(0xFEAD, 0xFEAE, 0xFEAD, 0xFEAE), // RA
  0x0632: _Forms(0xFEAF, 0xFEB0, 0xFEAF, 0xFEB0), // ZAY
  0x0633: _Forms(0xFEB1, 0xFEB2, 0xFEB3, 0xFEB4), // SEEN
  0x0634: _Forms(0xFEB5, 0xFEB6, 0xFEB7, 0xFEB8), // SHEEN
  0x0635: _Forms(0xFEB9, 0xFEBA, 0xFEBB, 0xFEBC), // SAD
  0x0636: _Forms(0xFEBD, 0xFEBE, 0xFEBF, 0xFEC0), // DAD
  0x0637: _Forms(0xFEC1, 0xFEC2, 0xFEC3, 0xFEC4), // TAH
  0x0638: _Forms(0xFEC5, 0xFEC6, 0xFEC7, 0xFEC8), // ZAH
  0x0639: _Forms(0xFEC9, 0xFECA, 0xFECB, 0xFECC), // AIN
  0x063A: _Forms(0xFECD, 0xFECE, 0xFECF, 0xFED0), // GHAIN
  0x0641: _Forms(0xFED1, 0xFED2, 0xFED3, 0xFED4), // FEH
  0x0642: _Forms(0xFED5, 0xFED6, 0xFED7, 0xFED8), // QAF
  0x0643: _Forms(0xFED9, 0xFEDA, 0xFEDB, 0xFEDC), // KAF
  0x0644: _Forms(0xFEDD, 0xFEDE, 0xFEDF, 0xFEE0), // LAM
  0x0645: _Forms(0xFEE1, 0xFEE2, 0xFEE3, 0xFEE4), // MEEM
  0x0646: _Forms(0xFEE5, 0xFEE6, 0xFEE7, 0xFEE8), // NOON
  0x0647: _Forms(0xFEE9, 0xFEEA, 0xFEEB, 0xFEEC), // HEH
  0x0648: _Forms(0xFEED, 0xFEEE, 0xFEED, 0xFEEE), // WAW
  0x0649: _Forms(0xFEEF, 0xFEF0, 0xFEEF, 0xFEF0), // ALEF MAKSURA
  0x064A: _Forms(0xFEF1, 0xFEF2, 0xFEF3, 0xFEF4), // YEH
};

// Lam-Alef ligatures (alef variants)
const Map<int, _Ligature> _lamAlefLigatures = {
  0x0622: _Ligature(0xFEF5, 0xFEF6), // LAM + ALEF MADDA
  0x0623: _Ligature(0xFEF7, 0xFEF8), // LAM + ALEF HAMZA ABOVE
  0x0625: _Ligature(0xFEF9, 0xFEFA), // LAM + ALEF HAMZA BELOW
  0x0627: _Ligature(0xFEFB, 0xFEFC), // LAM + ALEF
};

// Arabic diacritics and marks (transparent for joining)
bool _isTransparent(int code) {
  return (code >= 0x064B && code <= 0x065F) ||
      code == 0x0670 ||
      (code >= 0x06D6 && code <= 0x06ED);
}

int? _prevLetterIndex(List<int> runes, int index) {
  for (var i = index - 1; i >= 0; i--) {
    final ch = runes[i];
    if (_isTransparent(ch)) continue;
    return i;
  }
  return null;
}

int? _nextLetterIndex(List<int> runes, int index) {
  for (var i = index + 1; i < runes.length; i++) {
    final ch = runes[i];
    if (_isTransparent(ch)) continue;
    return i;
  }
  return null;
}

bool _canConnectPrev(int ch) {
  // Can connect to previous (right-joining)
  return _forms.containsKey(ch) && !_nonJoining.contains(ch);
}

bool _canConnectNext(int ch) {
  // Can connect to next (left-joining)
  return _forms.containsKey(ch) && !_rightOnly.contains(ch);
}

const Set<int> _nonJoining = {
  0x0621, // HAMZA
};

const Set<int> _rightOnly = {
  0x0621, // HAMZA
  0x0622, // ALEF MADDA
  0x0623, // ALEF HAMZA ABOVE
  0x0624, // WAW HAMZA
  0x0625, // ALEF HAMZA BELOW
  0x0627, // ALEF
  0x0629, // TEH MARBUTA
  0x062F, // DAL
  0x0630, // THAL
  0x0631, // RA
  0x0632, // ZAY
  0x0648, // WAW
  0x0649, // ALEF MAKSURA
};
