import 'dart:math';

/// Результат анализа одного окна аудио.
class PitchResult {
  /// Частота в Гц. null — тон не определён (тишина/шум).
  final double? frequency;

  /// Громкость окна (RMS). 0..1
  final double rms;

  const PitchResult(this.frequency, this.rms);
}

/// Автокорреляционный детектор высоты тона.
///
/// Работает над массивом сэмплов в диапазоне -1..1.
/// [sampleRate] — частота дискретизации (например, 44100).
/// [minFreq] / [maxFreq] — рабочий диапазон (по умолчанию человеческий голос).
class PitchDetector {
  final int sampleRate;
  final double minFreq;
  final double maxFreq;

  PitchDetector({
    required this.sampleRate,
    this.minFreq = 65.0, // C2
    this.maxFreq = 1000.0, // C6
  });

  /// Анализирует окно сэмплов и возвращает частоту + громкость.
  PitchResult analyze(List<double> samples) {
    if (samples.isEmpty) return const PitchResult(null, 0);

    // 1. Громкость (RMS)
    double sumSq = 0;
    for (final s in samples) {
      sumSq += s * s;
    }
    final rms = sqrt(sumSq / samples.length);

    // Если слишком тихо — считаем тишиной
    if (rms < 0.01) return PitchResult(null, rms);

    // 2. Убираем постоянную составляющую (DC offset)
    double mean = 0;
    for (final s in samples) {
      mean += s;
    }
    mean /= samples.length;

    final centered = List<double>.generate(
      samples.length,
      (i) => samples[i] - mean,
    );

    // 3. Автокорреляция
    final minLag = (sampleRate / maxFreq).floor();
    final maxLag = (sampleRate / minFreq).ceil();
    final maxLagClamped = min(maxLag, centered.length ~/ 2);

    if (maxLagClamped <= minLag) return PitchResult(null, rms);

    // Нормализованная автокорреляция
    double bestCorrelation = 0;
    int bestLag = -1;

    for (int lag = minLag; lag <= maxLagClamped; lag++) {
      double sum = 0;
      double normA = 0;
      double normB = 0;

      final limit = centered.length - lag;
      for (int i = 0; i < limit; i++) {
        final a = centered[i];
        final b = centered[i + lag];
        sum += a * b;
        normA += a * a;
        normB += b * b;
      }

      if (normA == 0 || normB == 0) continue;

      final correlation = sum / sqrt(normA * normB);
      if (correlation > bestCorrelation) {
        bestCorrelation = correlation;
        bestLag = lag;
      }
    }

    // Порог уверенности: если корреляция слишком слабая — это шум
    if (bestLag < 0 || bestCorrelation < 0.5) {
      return PitchResult(null, rms);
    }

    // 4. Параболическая интерполяция для уточнения лага
    double refinedLag = bestLag.toDouble();
    if (bestLag > minLag && bestLag < maxLagClamped) {
      final y1 = _correlationAt(centered, bestLag - 1);
      final y2 = _correlationAt(centered, bestLag);
      final y3 = _correlationAt(centered, bestLag + 1);
      final denom = 2 * (2 * y2 - y1 - y3);
      if (denom.abs() > 1e-9) {
        refinedLag += (y3 - y1) / denom;
      }
    }

    final freq = sampleRate / refinedLag;
    return PitchResult(freq, rms);
  }

  double _correlationAt(List<double> data, int lag) {
    if (lag <= 0 || lag >= data.length) return 0;
    double sum = 0;
    final limit = data.length - lag;
    for (int i = 0; i < limit; i++) {
      sum += data[i] * data[i + lag];
    }
    return sum;
  }
}

/// Преобразование частоты (Гц) в ближайшую MIDI-ноту и отклонение в центах.
class NoteFromFrequency {
  /// MIDI-нота (целое). 69 = A4.
  final int midi;

  /// Отклонение от точной ноты в центах. -50..+50.
  final double cents;

  /// Исходная частота.
  final double frequency;

  const NoteFromFrequency(this.midi, this.cents, this.frequency);

  /// Имя ноты и октава. Например, "A4".
  String name(List<String> pitchNames) {
    final pc = midi % 12;
    final octave = (midi ~/ 12) - 1;
    return '${pitchNames[pc]}$octave';
  }

  /// Насколько «в ноту» попал пользователь. 0 — идеально.
  bool get isInTune => cents.abs() < 10.0;
}

NoteFromFrequency? frequencyToNote(double freq, {double a4 = 440.0}) {
  if (freq <= 0) return null;
  final midiFloat = 69 + 12 * (log(freq / a4) / ln2);
  final midi = midiFloat.round();
  final cents = (midiFloat - midi) * 100.0;
  return NoteFromFrequency(midi, cents, freq);
}

const double ln2 = 0.6931471805599453;

/// Фильтр: сглаживает поток частот (медиана последних N значений).
class FrequencySmoother {
  final int windowSize;
  final List<double?> _buf = [];

  FrequencySmoother({this.windowSize = 5});

  double? add(double? freq) {
    _buf.add(freq);
    if (_buf.length > windowSize) _buf.removeAt(0);

    final valid = _buf.whereType<double>().toList();
    if (valid.isEmpty) return null;

    valid.sort();
    return valid[valid.length ~/ 2]; // медиана
  }

  void reset() => _buf.clear();
}
