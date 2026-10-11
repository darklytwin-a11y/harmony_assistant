import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';

/// Синтез чистого тона и воспроизведение.
class AudioService {
  final AudioPlayer _player = AudioPlayer();
  final Map<String, File> _cache = {};

  /// Играет один или несколько тонов одновременно (аккорд гармонии).
  Future<void> playFrequencies(
    List<double> freqs, {
    double duration = 1.2,
    double volume = 0.4,
  }) async {
    if (freqs.isEmpty) return;

    final key = freqs.map((f) => f.toStringAsFixed(2)).join('_');
    File? file = _cache[key];

    if (file == null || !await file.exists()) {
      final bytes = _generateWav(freqs, duration, volume);
      final dir = await getTemporaryDirectory();
      file = File('${dir.path}/harm_${key.hashCode}.wav');
      await file.writeAsBytes(bytes, flush: true);
      _cache[key] = file;
    }

    await _player.stop();
    await _player.play(DeviceFileSource(file.path));
  }

  Future<void> stop() async {
    await _player.stop();
  }

  // -------- Генерация WAV (PCM 16-bit mono 44.1 kHz) --------

  Uint8List _generateWav(
      List<double> freqs, double duration, double volume) {
    const sampleRate = 44100;
    final numSamples = (sampleRate * duration).round();
    final samples = Int16List(numSamples);

    for (int i = 0; i < numSamples; i++) {
      double v = 0;
      for (final f in freqs) {
        v += sin(2 * pi * f * i / sampleRate);
      }
      v /= freqs.length;

      // Плавное затухание в конце
      final t = i / numSamples;
      final env = t < 0.7 ? 1.0 : (1.0 - t) / 0.3;

      v *= volume * env;
      samples[i] = (v * 32767).clamp(-32768, 32767).toInt();
    }
    return _wavBytes(samples);
  }

  Uint8List _wavBytes(Int16List samples) {
    final dataSize = samples.length * 2;
    final fileSize = 36 + dataSize;
    final out = Uint8List(44 + dataSize);
    final bd = ByteData.view(out.buffer);

    void w(int off, String s) {
      for (int i = 0; i < s.length; i++) {
        out[off + i] = s.codeUnitAt(i);
      }
    }

    w(0, 'RIFF');
    bd.setUint32(4, fileSize, Endian.little);
    w(8, 'WAVE');
    w(12, 'fmt ');
    bd.setUint32(16, 16, Endian.little);
    bd.setUint16(20, 1, Endian.little); // PCM
    bd.setUint16(22, 1, Endian.little); // mono
    bd.setUint32(24, 44100, Endian.little);
    bd.setUint32(28, 44100 * 2, Endian.little);
    bd.setUint16(32, 2, Endian.little);
    bd.setUint16(34, 16, Endian.little);
    w(36, 'data');
    bd.setUint32(40, dataSize, Endian.little);

    out.setRange(44, 44 + dataSize, samples.buffer.asUint8List());
    return out;
  }

  void dispose() {
    _player.dispose();
  }
}
