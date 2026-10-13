import 'dart:async';
import 'dart:typed_data';
import 'package:record/record.dart';
import 'pitch_detector.dart';

/// Захват аудио с микрофона и стрим результатов анализа.
class MicService {
  final AudioRecorder _recorder = AudioRecorder();
  final PitchDetector _detector = PitchDetector(sampleRate: 44100);

  StreamSubscription<Uint8List>? _sub;
  final List<double> _buffer = [];
  static const int _windowSize = 2048;

  final StreamController<PitchResult> _pitchController =
      StreamController<PitchResult>.broadcast();

  /// Поток с частотой + громкостью, обновляется ~20 раз в секунду.
  Stream<PitchResult> get pitchStream => _pitchController.stream;

  bool _running = false;

  /// Проверка разрешения на использование микрофона.
  Future<bool> hasPermission() => _recorder.hasPermission();

  /// Запустить захват. Бросает исключение, если нет разрешения.
  Future<void> start() async {
    if (_running) return;

    if (!await hasPermission()) {
      throw Exception('Нет разрешения на использование микрофона');
    }

    _running = true;
    _buffer.clear();

    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 44100,
        numChannels: 1,
      ),
    );

    _sub = stream.listen(
      _onChunk,
      onError: (e) {
        _pitchController.addError(e);
      },
    );
  }

  /// Остановить захват.
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    await _sub?.cancel();
    _sub = null;
    await _recorder.stop();
    _buffer.clear();
  }

  void _onChunk(Uint8List chunk) {
    // Конвертируем 16-bit PCM → double в диапазоне -1..1
    final bd = ByteData.view(
      chunk.buffer,
      chunk.offsetInBytes,
      chunk.length,
    );
    for (int i = 0; i + 1 < chunk.length; i += 2) {
      final sample = bd.getInt16(i, Endian.little) / 32768.0;
      _buffer.add(sample);
    }

    // Обрабатываем окна фиксированного размера
    while (_buffer.length >= _windowSize) {
      final window = _buffer.sublist(0, _windowSize);
      _buffer.removeRange(0, _windowSize);
      final result = _detector.analyze(window);
      _pitchController.add(result);
    }
  }

  Future<void> dispose() async {
    await stop();
    await _recorder.dispose();
    await _pitchController.close();
  }
}
