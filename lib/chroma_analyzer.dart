import 'dart:math';
import 'dart:typed_data';

import 'fft.dart';
import 'music_theory.dart';
import 'key_detector.dart';

const double _ln2 = 0.6931471805599453;

const List<double> _krumhanslMajor = [
  6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88
];
const List<double> _krumhanslMinor = [
  6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17
];

class FileAnalysisResult {
  final List<double> chroma;
  final List<KeyCandidate> keyCandidates;
  final Duration duration;
  final int frameCount;
  final double? lowestFreq;
  final double? highestFreq;
  final int? lowestMidi;
  final int? highestMidi;
  final VoiceRange? detectedVoice;

  FileAnalysisResult({
    required this.chroma,
    required this.keyCandidates,
    required this.duration,
    required this.frameCount,
    this.lowestFreq,
    this.highestFreq,
    this.lowestMidi,
    this.highestMidi,
    this.detectedVoice,
  });
}

FileAnalysisResult analyzeWav(
  WavData wav, {
  int frameSize = 4096,
  int hopSize = 2048,
  double a4 = 440.0,
}) {
  final samples = wav.samples;
  final sampleRate = wav.sampleRate;

  if (samples.length < frameSize) {
    return FileAnalysisResult(
      chroma: List<double>.filled(12, 0),
      keyCandidates: const [],
      duration: wav.duration,
      frameCount: 0,
    );
  }

  final hann = hannWindow(frameSize);
  final chromaAccum = List<double>.filled(12, 0.0);
  final frameF0s = <double>[];

  const fMin = 80.0;   // ниже E2 — басы
  const fMax = 2000.0; // выше C7 — обертоны
  const f0Min = 80.0;  // границы поиска основного тона голоса
  const f0Max = 600.0; // до D5 хватит с головой (для детей и женских)
  final binCount = frameSize ~/ 2;
  final freqPerBin = sampleRate / frameSize;

  int frameCount = 0;

  for (int start = 0;
      start + frameSize <= samples.length;
      start += hopSize) {
    final window = Float64List(frameSize);
    for (int i = 0; i < frameSize; i++) {
      window[i] = samples[start + i] * hann[i];
    }

    final mag = magnitudeSpectrum(window);

    double maxMag = 0;
    for (int i = 0; i < binCount; i++) {
      if (mag[i] > maxMag) maxMag = mag[i];
    }
    if (maxMag < 1e-4) continue;

    // --- Оценка f0 для этого кадра ---
    // Ищем сильнейший пик в диапазоне 80–600 Гц.
    // Для голоса фундаментальная частота обычно доминирует.
    double peakMag = 0;
    int peakBin = -1;
    for (int bin = 1; bin < binCount; bin++) {
      final freq = bin * freqPerBin;
      if (freq < f0Min) continue;
      if (freq > f0Max) break;
      if (mag[bin] > peakMag) {
        peakMag = mag[bin];
        peakBin = bin;
      }
    }

    // Принимаем кадр, только если пик чётко выделяется
    if (peakBin > 0 && peakMag > maxMag * 0.15) {
      // Проверка на субгармонику: если пик выше 180 Гц,
      // проверяем, нет ли сильного пика на половине частоты
      // (типичная ошибка — 2-я гармоника сильнее фундамента).
      if (peakBin * freqPerBin > 180) {
        final halfBin = peakBin ~/ 2;
        double bestHalf = 0;
        int bestHalfBin = -1;
        for (int b = max(1, halfBin - 2);
            b <= min(binCount - 1, halfBin + 2);
            b++) {
          if (mag[b] > bestHalf) {
            bestHalf = mag[b];
            bestHalfBin = b;
          }
        }
        // Если половинный пик достаточно силён — используем его
        if (bestHalfBin > 0 && bestHalf > peakMag * 0.35) {
          peakBin = bestHalfBin;
        }
      }

      frameF0s.add(peakBin * freqPerBin);
    }

    // --- Хромаграмма ---
    final frameChroma = List<double>.filled(12, 0.0);
    int usedBins = 0;

    for (int bin = 1; bin < binCount; bin++) {
      final freq = bin * freqPerBin;
      if (freq < fMin || freq > fMax) continue;

      final m = mag[bin];
      if (m < maxMag * 0.05) continue;

      final midiFloat = 69 + 12 * (log(freq / a4) / _ln2);
      final lower = midiFloat.floor();
      final frac = midiFloat - lower;
      final pcLow = ((lower % 12) + 12) % 12;
      final pcHigh = ((lower + 1) % 12) % 12;

      frameChroma[pcLow] += m * (1 - frac);
      frameChroma[pcHigh] += m * frac;
      usedBins++;
    }

    if (usedBins < 5) continue;

    double frameMax = 0;
    for (int i = 0; i < 12; i++) {
      if (frameChroma[i] > frameMax) frameMax = frameChroma[i];
    }
    if (frameMax > 0) {
      for (int i = 0; i < 12; i++) {
        frameChroma[i] /= frameMax;
      }
    }

    for (int i = 0; i < 12; i++) {
      chromaAccum[i] += frameChroma[i];
    }
    frameCount++;
  }

  if (frameCount == 0) {
    return FileAnalysisResult(
      chroma: List<double>.filled(12, 0),
      keyCandidates: const [],
      duration: wav.duration,
      frameCount: 0,
    );
  }

  final chromaAvg = List<double>.generate(
    12,
    (i) => chromaAccum[i] / frameCount,
  );
  final keyCandidates = detectKeyFromChroma(chromaAvg);

  // --- Оценка вокального диапазона по реальным f0 ---
  double? lowestFreq;
  double? highestFreq;
  int? lowestMidi;
  int? highestMidi;
  VoiceRange? detectedVoice;

  if (frameF0s.length >= 30) {
    frameF0s.sort();
    // Берём 10-й и 90-й процентили — отсекаем случайные выбросы
    final p10 = frameF0s[(frameF0s.length * 0.10).floor()];
    final p90 = frameF0s[(frameF0s.length * 0.90).floor()];

    // Если разброс больше 3 октав — вероятно полифония или шум
    if (p10 > 0 && p90 / p10 < 8.0) {
      lowestFreq = p10;
      highestFreq = p90;
      lowestMidi = (69 + 12 * (log(p10 / a4) / _ln2)).round();
      highestMidi = (69 + 12 * (log(p90 / a4) / _ln2)).round();
      detectedVoice = _matchVoiceRange(lowestMidi, highestMidi);
    }
  }

  return FileAnalysisResult(
    chroma: chromaAvg,
    keyCandidates: keyCandidates,
    duration: wav.duration,
    frameCount: frameCount,
    lowestFreq: lowestFreq,
    highestFreq: highestFreq,
    lowestMidi: lowestMidi,
    highestMidi: highestMidi,
    detectedVoice: detectedVoice,
  );
}

// ============================================================
//  ПОДБОР ТИПА ГОЛОСА ПО ДИАПАЗОНУ
// ============================================================

/// Голоса от высоких к низким.
const List<VoiceRange> _voicesByHeight = [
  VoiceRange('Soprano', 60, 84, VoiceGender.female),
  VoiceRange('Mezzo-Soprano', 57, 81, VoiceGender.female),
  VoiceRange('Alto', 53, 77, VoiceGender.female),
  VoiceRange('Tenor', 48, 72, VoiceGender.male),
  VoiceRange('Baritone', 45, 69, VoiceGender.male),
  VoiceRange('Bass', 40, 64, VoiceGender.male),
];

/// Подбираем САМЫЙ ВЫСОКИЙ голос, чей диапазон покрывает спетый
/// (с допуском ±2 полутона на неточность распознавания).
VoiceRange? _matchVoiceRange(int lowMidi, int highMidi) {
  const tolerance = 2;
  for (final v in _voicesByHeight) {
    if (lowMidi >= v.minMidi - tolerance &&
        highMidi <= v.maxMidi + tolerance) {
      return v;
    }
  }
  // Ничего не подошло — возвращаем по среднему значению
  final center = (lowMidi + highMidi) ~/ 2;
  VoiceRange? best;
  int bestDist = 1000;
  for (final v in _voicesByHeight) {
    final vCenter = (v.minMidi + v.maxMidi) ~/ 2;
    final d = (vCenter - center).abs();
    if (d < bestDist) {
      bestDist = d;
      best = v;
    }
  }
  return best;
}

// ============================================================
//  ОПРЕДЕЛЕНИЕ ТОНАЛЬНОСТИ ПО ХРОМАГРАММЕ
// ============================================================

double _pearson(List<double> a, List<double> b) {
  final n = a.length;
  double meanA = 0, meanB = 0;
  for (int i = 0; i < n; i++) {
    meanA += a[i];
    meanB += b[i];
  }
  meanA /= n;
  meanB /= n;

  double num = 0, denA = 0, denB = 0;
  for (int i = 0; i < n; i++) {
    final da = a[i] - meanA;
    final db = b[i] - meanB;
    num += da * db;
    denA += da * da;
    denB += db * db;
  }
  if (denA == 0 || denB == 0) return 0;
  return num / sqrt(denA * denB);
}

List<double> _rotateToTonic(List<double> profile, int tonic) {
  return List<double>.generate(
    12,
    (i) => profile[(i - tonic + 12) % 12],
  );
}

List<KeyCandidate> detectKeyFromChroma(List<double> chroma) {
  final results = <KeyCandidate>[];

  for (int tonic = 0; tonic < 12; tonic++) {
    final majorCorr =
        _pearson(chroma, _rotateToTonic(_krumhanslMajor, tonic));
    final minorCorr =
        _pearson(chroma, _rotateToTonic(_krumhanslMinor, tonic));

    results.add(KeyCandidate(Scale(tonic, ScaleType.major), majorCorr));
    results.add(
        KeyCandidate(Scale(tonic, ScaleType.naturalMinor), minorCorr));
  }

  for (int i = 0; i < results.length; i++) {
    final c = results[i];
    results[i] = KeyCandidate(c.scale, (c.score + 1) / 2);
  }

  results.sort((a, b) => b.score.compareTo(a.score));
  return results.take(4).toList();
}
