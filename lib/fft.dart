import 'dart:math';
import 'dart:typed_data';

// ============================================================
//  1. ПАРСЕР WAV-ФАЙЛОВ (PCM 16-bit)
// ============================================================

/// Разобранный WAV-файл: моно-сигнал в диапазоне -1..1.
class WavData {
  final Float32List samples;
  final int sampleRate;
  final Duration duration;

  WavData(this.samples, this.sampleRate)
      : duration = Duration(
          milliseconds: (samples.length / sampleRate * 1000).round(),
        );
}

/// Парсит WAV (только PCM 16-bit). Возвращает null, если формат неподдерживаемый.
/// Стерео микшируется в моно усреднением каналов.
WavData? parseWav(Uint8List bytes) {
  if (bytes.length < 44) return null;

  // Заголовок RIFF
  if (bytes[0] != 0x52 || bytes[1] != 0x49 ||
      bytes[2] != 0x46 || bytes[3] != 0x46) {
    return null;
  }
  // Формат WAVE
  if (bytes[8] != 0x57 || bytes[9] != 0x41 ||
      bytes[10] != 0x56 || bytes[11] != 0x45) {
    return null;
  }

  final bd = ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length);

  int offset = 12;
  int? sampleRate;
  int? numChannels;
  int? bitsPerSample;
  int? dataOffset;
  int? dataLength;

  while (offset + 8 <= bytes.length) {
    final chunkId = String.fromCharCodes(
      bytes.sublist(offset, offset + 4),
    );
    final chunkSize = bd.getUint32(offset + 4, Endian.little);

    if (chunkId == 'fmt ') {
      final audioFormat = bd.getUint16(offset + 8, Endian.little);
      // 1 = PCM, 0xFFFE = WAVE_FORMAT_EXTENSIBLE (тоже PCM по сути)
      if (audioFormat != 1 && audioFormat != 0xFFFE) return null;
      numChannels = bd.getUint16(offset + 10, Endian.little);
      sampleRate = bd.getUint32(offset + 12, Endian.little);
      bitsPerSample = bd.getUint16(offset + 22, Endian.little);
    } else if (chunkId == 'data') {
      dataOffset = offset + 8;
      dataLength = chunkSize;
    }

    offset += 8 + chunkSize;
    if (chunkSize % 2 == 1) offset++;
  }

  if (sampleRate == null ||
      numChannels == null ||
      bitsPerSample == null ||
      dataOffset == null ||
      dataLength == null) {
    return null;
  }
  if (bitsPerSample != 16) return null;

  if (dataOffset + dataLength > bytes.length) {
    dataLength = bytes.length - dataOffset;
  }

  final totalSamples = dataLength ~/ 2;
  if (totalSamples <= 0) return null;

  final frames = totalSamples ~/ numChannels;
  final mono = Float32List(frames);

  for (int i = 0; i < frames; i++) {
    double sum = 0;
    for (int c = 0; c < numChannels; c++) {
      final idx = dataOffset + (i * numChannels + c) * 2;
      sum += bd.getInt16(idx, Endian.little) / 32768.0;
    }
    mono[i] = sum / numChannels;
  }

  return WavData(mono, sampleRate);
}

// ============================================================
//  2. FFT (Cooley-Tukey, radix-2, итеративный)
// ============================================================

/// Проверяет, что n — степень двойки.
bool _isPow2(int n) => n > 0 && (n & (n - 1)) == 0;

/// Следующая степень двойки, не меньшая n.
int nextPow2(int n) {
  if (n <= 1) return 1;
  int p = 1;
  while (p < n) {
    p <<= 1;
  }
  return p;
}

/// Быстрое преобразование Фурье на месте.
/// [real] и [imag] должны иметь одинаковую длину, равную степени двойки.
/// После вызова содержат комплексный спектр.
void fft(Float64List real, Float64List imag) {
  final n = real.length;
  if (n <= 1) return;
  if (imag.length != n) {
    throw ArgumentError('real и imag должны быть одинаковой длины');
  }
  if (!_isPow2(n)) {
    throw ArgumentError('Длина должна быть степенью двойки, получено $n');
  }

  // 1. Bit-reversal permutation
  int j = 0;
  for (int i = 0; i < n; i++) {
    if (i < j) {
      final tr = real[i];
      real[i] = real[j];
      real[j] = tr;
      final ti = imag[i];
      imag[i] = imag[j];
      imag[j] = ti;
    }
    int m = n >> 1;
    while (m >= 1 && j >= m) {
      j -= m;
      m >>= 1;
    }
    j += m;
  }

  // 2. Butterfly
  for (int len = 2; len <= n; len <<= 1) {
    final ang = -2 * pi / len;
    final wReal = cos(ang);
    final wImag = sin(ang);
    final half = len >> 1;

    for (int i = 0; i < n; i += len) {
      double curReal = 1.0;
      double curImag = 0.0;

      for (int k = 0; k < half; k++) {
        final uR = real[i + k];
        final uI = imag[i + k];
        final vR = real[i + k + half] * curReal -
            imag[i + k + half] * curImag;
        final vI = real[i + k + half] * curImag +
            imag[i + k + half] * curReal;

        real[i + k] = uR + vR;
        imag[i + k] = uI + vI;
        real[i + k + half] = uR - vR;
        imag[i + k + half] = uI - vI;

        final newReal = curReal * wReal - curImag * wImag;
        final newImag = curReal * wImag + curImag * wReal;
        curReal = newReal;
        curImag = newImag;
      }
    }
  }
}

/// Обёртка: считает амплитудный спектр для окна сэмплов.
/// Возвращает массив длиной n/2 (только положительные частоты).
Float64List magnitudeSpectrum(Float64List samples) {
  final n = samples.length;
  final real = Float64List(n);
  final imag = Float64List(n);
  real.setAll(0, samples);

  fft(real, imag);

  final half = n ~/ 2;
  final mag = Float64List(half);
  for (int i = 0; i < half; i++) {
    mag[i] = sqrt(real[i] * real[i] + imag[i] * imag[i]);
  }
  return mag;
}

/// Оконная функция Ханна (применяется до FFT, чтобы уменьшить утечку).
Float64List hannWindow(int n) {
  final w = Float64List(n);
  for (int i = 0; i < n; i++) {
    w[i] = 0.5 * (1.0 - cos(2 * pi * i / (n - 1)));
  }
  return w;
}
