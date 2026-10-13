import 'dart:math';
import 'dart:typed_data';

import 'fft.dart';
import 'music_theory.dart';
import 'key_detector.dart';

// ============================================================
//  АНАЛИЗ АУДИОФАЙЛА: ХРОМАГРАММА + КРАМХАНСЛЬ-ШМУКЛЕР
// ============================================================

const double _ln2 = 0.6931471805599453;

/// Эталонные профили Крамхансля-Шмуклера для мажора и минора.
/// Индекс = полутон от тоники (0 = тоника, 1 = малая секунда и т.д.).
const List<double> _krumhanslMajor = [
  6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88
];
const List<double> _krumhanslMinor = [
  6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17
];

/// Результат полного анализа файла.
class FileAnalysisResult {
  /// Хромаграмма: 12 значений (0 = C, 1 = C#, ..., 11 = B), нормализована 0..1.
  final List<double> chroma;

  /// Топ-4 вероятных тональности.
  final List<KeyCandidate> keyCandidates;

  /// Примерная частота самой низкой и самой высокой ноты в сольном вокале.
  /// null, если материал полифонический (минусовка).
  final double? lowestFreq;
  final double? highestFreq;

  /// Примерный предполагаемый тип голоса (или null).
  final VoiceRange? detectedVoice;

  /// Длительность анализируемого файла.
  final Duration duration;

  /// Сколько кадров было обработано (для отладки).
  final int frameCount;

  FileAnalysisResult({
    required this.chroma,
    required this.keyCandidates,
    required this.duration,
    required this.frameCount,
    this.lowestFreq,
    this.highestFreq,
    this.detectedVoice,
  });
}

/// Полный анализ WAV-файла.
///
/// [frameSize] — размер окна FFT (должен быть степенью двойки).
/// [hopSize] — шаг между окнами.
/// [a4] — эталонная частота для расчёта питчей.
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
  final frameChromas = <List<double>>[];

  // Границы частотного диапазона (человеческий вокал + аккомпанемент)
  const fMin = 80.0;   // ниже E2 — почти всегда басовая линия
  const fMax = 2000.0; // выше C7 — уже обертоны, их не берём
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

    // Локальный шумовой порог (чтобы тихие кадры не портили хромаграмму)
    double maxMag = 0;
    for (int i = 0; i < binCount; i++) {
      if (mag[i] > maxMag) maxMag = mag[i];
    }
    if (maxMag < 1e-4) continue; // тишина

    final frameChroma = List<double>.filled(12, 0.0);
    int usedBins = 0;

    for (int bin = 1; bin < binCount; bin++) {
      final freq = bin * freqPerBin;
      if (freq < fMin || freq > fMax) continue;

      final m = mag[bin];
      if (m < maxMag * 0.05) continue; // отсеиваем слабые бины

      // Частота → MIDI-нота (float)
      final midiFloat = 69 + 12 * (log(freq / a4) / _ln2);

      // Распределяем энергию между двумя ближайшими питч-классами
      final lower = midiFloat.floor();
      final frac = midiFloat - lower;

      final pcLow = ((lower % 12) + 12) % 12;
      final pcHigh = ((lower + 1) % 12) % 12;

      frameChroma[pcLow] += m * (1 - frac);
      frameChroma[pcHigh] += m * frac;
      usedBins++;
    }

    if (usedBins < 5) continue;

    // Нормализуем кадр
    double frameMax = 0;
    for (int i = 0; i < 12; i++) {
      if (frameChroma[i] > frameMax) frameMax = frameChroma[i];
    }
    if (frameMax > 0) {
      for (int i = 0; i < 12; i++) {
        frameChroma[i] /= frameMax;
      }
    }

    frameChromas.add(frameChroma);
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

  // Усреднённая хромаграмма
  final chromaAvg = List<double>.generate(
    12,
    (i) => chromaAccum[i] / frameCount,
  );

  // Определение тональности
  final keyCandidates = detectKeyFromChroma(chromaAvg);

  // Оценка диапазона для сольного вокала
  final rangeInfo = _estimateVocalRange(frameChromas);

  return FileAnalysisResult(
    chroma: chromaAvg,
    keyCandidates: keyCandidates,
    duration: wav.duration,
    frameCount: frameCount,
    lowestFreq: rangeInfo.lowest,
    highestFreq: rangeInfo.highest,
    detectedVoice: rangeInfo.voice,
  );
}

// ============================================================
//  ОПРЕДЕЛЕНИЕ ТОНАЛЬНОСТИ ПО ХРОМАГРАММЕ
// ============================================================

/// Корреляция Пирсона между двумя массивами.
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

/// Сдвигает профиль так, чтобы тоника оказалась в индексе 0.
List<double> _rotateToTonic(List<double> profile, int tonic) {
  return List<double>.generate(
    12,
    (i) => profile[(i - tonic + 12) % 12],
  );
}

/// Определяет тональность по 12-элементной хромаграмме.
List<KeyCandidate> detectKeyFromChroma(List<double> chroma) {
  final results = <KeyCandidate>[];

  for (int tonic = 0; tonic < 12; tonic++) {
    final majorCorr = _pearson(chroma, _rotateToTonic(_krumhanslMajor, tonic));
    final minorCorr = _pearson(chroma, _rotateToTonic(_krumhanslMinor, tonic));

    results.add(KeyCandidate(Scale(tonic, ScaleType.major), majorCorr));
    results.add(KeyCandidate(Scale(tonic, ScaleType.naturalMinor), minorCorr));
  }

  // Переводим корреляцию (-1..1) в шкалу 0..1 для удобства отображения
  for (int i = 0; i < results.length; i++) {
    final c = results[i];
    results[i] = KeyCandidate(c.scale, (c.score + 1) / 2);
  }

  results.sort((a, b) => b.score.compareTo(a.score));
  return results.take(4).toList();
}

// ============================================================
//  ОЦЕНКА ВОКАЛЬНОГО ДИАПАЗОНА
// ============================================================

class _RangeInfo {
  final double? lowest;
  final double? highest;
  final VoiceRange? voice;
  _RangeInfo(this.lowest, this.highest, this.voice);
}

/// Грубая оценка диапазона по кадрам: берём самый сильный питч в кадре,
/// строим кривую «мелодии», считаем min и max.
_RangeInfo _estimateVocalRange(List<List<double>> frameChromas) {
  if (frameChromas.length < 20) return _RangeInfo(null, null, null);

  // Для каждого кадра — самый сильный питч-класс.
  // Затем считаем, сколько разных питч-классов доминирует.
  // Если их > 6 — вероятно, полифония, не считаем.
  final dominantPcs = <int>[];
  for (final frame in frameChromas) {
    int best = 0;
    double bestVal = frame[0];
    double sum = 0;
    for (int i = 0; i < 12; i++) {
      sum += frame[i];
      if (frame[i] > bestVal) {
        bestVal = frame[i];
        best = i;
      }
    }
    // Если пик слабо выражен (хрома размазана) — пропускаем кадр
    if (sum > 0 && bestVal / sum > 0.35) {
      dominantPcs.add(best);
    }
  }

  if (dominantPcs.length < 20) return _RangeInfo(null, null, null);

  // Сколько уникальных доминирующих питчей?
  final uniquePcs = dominantPcs.toSet();
  // Для сольного вокала обычно 3-7 разных нот в мелодии
  if (uniquePcs.length > 9) {
    return _RangeInfo(null, null, null); // полифония
  }

  // Определяем примерную октаву: средний питч-класс + типичная вокальная октава.
  // Точнее без партитуры не определим, но для оценки тона голоса хватит.

  // Более практичная оценка — просто диапазон MIDI в средней октаве.
  // Возьмём питч-классы, спроецируем на октаву 3–4 (для удобства).
  // Для мужских голосов используем 2–3, для женских 4–5.

  // Простейшая эвристика: если доминирующие питчи — низкие (C, C#, D, D#),
  // это скорее мужской голос, если высокие (A, A#, B) — женский.
  final avgPc = dominantPcs.reduce((a, b) => a + b) / dominantPcs.length;

  final isMale = avgPc < 5 || avgPc > 9; // грубо: ближе к C/D или к A/B

  // Оценка диапазона: 2 октавы, смещённые относительно среднего питча
  const baseMale = 45; // A2
  const baseFemale = 57; // A3
  final base = isMale ? baseMale : baseFemale;

  final lowestMidi = base;
  final highestMidi = base + 24;

  final lowestFreq = Note(lowestMidi).frequency();
  final highestFreq = Note(highestMidi).frequency();

  // Определяем наиболее вероятный тип голоса по базовой октаве
  final gender = isMale ? VoiceGender.male : VoiceGender.female;
  VoiceRange? best;
  int bestScore = -1;
  for (final v in voiceRanges) {
    if (v.gender != gender) continue;
    // Насколько база близка к началу диапазона голоса
    final diff = (v.minMidi - base).abs();
    final score = 100 - diff;
    if (score > bestScore) {
      bestScore = score;
      best = v;
    }
  }

  return _RangeInfo(lowestFreq, highestFreq, best);
}
