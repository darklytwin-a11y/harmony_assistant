import 'dart:math';

// ============================================================
//  МУЗЫКАЛЬНАЯ ТЕОРИЯ: НОТЫ, ЛАДЫ, ИНТЕРВАЛЫ, ГОЛОСА
// ============================================================

const List<String> latinNames = [
  'C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'
];

const List<String> germanNames = [
  'C', 'Cis', 'D', 'Dis', 'E', 'F', 'Fis', 'G', 'Gis', 'A', 'Ais', 'H'
];

enum ScaleType {
  major('Major', [0, 2, 4, 5, 7, 9, 11]),
  naturalMinor('Minor', [0, 2, 3, 5, 7, 8, 10]),
  harmonicMinor('Harmonic Minor', [0, 2, 3, 5, 7, 8, 11]),
  melodicMinor('Melodic Minor', [0, 2, 3, 5, 7, 9, 11]),
  dorian('Dorian', [0, 2, 3, 5, 7, 9, 10]),
  phrygian('Phrygian', [0, 1, 3, 5, 7, 8, 10]),
  lydian('Lydian', [0, 2, 4, 6, 7, 9, 11]),
  mixolydian('Mixolydian', [0, 2, 4, 5, 7, 9, 10]),
  locrian('Locrian', [0, 1, 3, 5, 6, 8, 10]);

  final String label;
  final List<int> intervals;
  const ScaleType(this.label, this.intervals);
}

class Note {
  final int midi;
  const Note(this.midi);

  int get pitchClass => midi % 12;
  int get octave => (midi ~/ 12) - 1;

  double frequency([double a4 = 440.0]) =>
      a4 * pow(2.0, (midi - 69) / 12.0);

  String get latinName => '${latinNames[pitchClass]}$octave';
  String get germanName => '${germanNames[pitchClass]}$octave';

  Note transpose(int semitones) => Note(midi + semitones);

  @override
  String toString() => latinName;
}

class Scale {
  final int tonicPc;
  final ScaleType type;
  const Scale(this.tonicPc, this.type);

  List<int> get pitchClasses =>
      type.intervals.map((i) => (tonicPc + i) % 12).toList();

  String get name => '${latinNames[tonicPc]} ${type.label}';

  bool contains(Note n) => pitchClasses.contains(n.pitchClass);

  static const int _baseOctave = -1;
  int get _baseMidi => tonicPc + (_baseOctave + 1) * 12;

  int? findPosition(Note source) {
    for (int p = 0; p < 200; p++) {
      final midi = _baseMidi + (p ~/ 7) * 12 + type.intervals[p % 7];
      if (midi == source.midi) return p;
      if (midi > source.midi) return null;
    }
    return null;
  }

  Note noteAt(int position) {
    final midi =
        _baseMidi + (position ~/ 7) * 12 + type.intervals[position % 7];
    return Note(midi);
  }

  Note? harmony(Note source, int intervalSteps, int direction) {
    final p = findPosition(source);
    if (p == null) return null;
    final target = p + direction * intervalSteps;
    if (target < 0) return null;
    return noteAt(target);
  }
}

// -------- Диапазоны голосов --------

enum VoiceGender { male, female }

class VoiceRange {
  final String label;
  final int minMidi;
  final int maxMidi;
  final VoiceGender gender;
  const VoiceRange(this.label, this.minMidi, this.maxMidi, this.gender);
}

const List<VoiceRange> voiceRanges = [
  VoiceRange('Soprano', 60, 84, VoiceGender.female),
  VoiceRange('Mezzo-Soprano', 57, 81, VoiceGender.female),
  VoiceRange('Alto', 53, 77, VoiceGender.female),
  VoiceRange('Tenor', 48, 72, VoiceGender.male),
  VoiceRange('Baritone', 45, 69, VoiceGender.male),
  VoiceRange('Bass', 40, 64, VoiceGender.male),
];

class HarmonyVoice {
  final Note note;
  final bool inRange;
  final List<String> warnings;

  HarmonyVoice(this.note, this.inRange, this.warnings);

  String get latinName => note.latinName;
  String get germanName => note.germanName;
}
