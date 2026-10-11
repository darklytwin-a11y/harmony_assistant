import 'music_theory.dart';

class KeyCandidate {
  final Scale scale;
  final double score; // 0..1
  KeyCandidate(this.scale, this.score);
}

/// Простой детектор тональности по набору сыгранных нот.
List<KeyCandidate> detectKeys(List<Note> playedNotes) {
  if (playedNotes.isEmpty) return [];

  final pcs = playedNotes.map((n) => n.pitchClass).toSet();

  final results = <KeyCandidate>[];
  final candidateTypes = [
    ScaleType.major,
    ScaleType.naturalMinor,
  ];

  for (int tonic = 0; tonic < 12; tonic++) {
    for (final type in candidateTypes) {
      final scale = Scale(tonic, type);
      final scalePcs = scale.pitchClasses.toSet();

      // Совпадения: сколько сыгранных нот попадает в лад
      final matches = pcs.where(scalePcs.contains).length;
      // Штраф за пропущенные ступени лада
      final missed = scalePcs.where((pc) => !pcs.contains(pc)).length;

      final score =
          (matches / pcs.length) * 0.75 + ((7 - missed) / 7) * 0.25;
      results.add(KeyCandidate(scale, score));
    }
  }

  results.sort((a, b) => b.score.compareTo(a.score));
  return results.take(4).toList();
}
