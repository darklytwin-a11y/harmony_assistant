import 'dart:async';
import 'package:flutter/material.dart';

import 'mic_service.dart';
import 'pitch_detector.dart';
import 'music_theory.dart';
import 'key_detector.dart';

class TunerScreen extends StatefulWidget {
  const TunerScreen({super.key});
  @override
  State<TunerScreen> createState() => _TunerScreenState();
}

enum TunerMode { tuner, record }

class _TunerScreenState extends State<TunerScreen> {
  final MicService _mic = MicService();
  final FrequencySmoother _smoother = FrequencySmoother(windowSize: 5);

  TunerMode _mode = TunerMode.tuner;
  bool _listening = false;
  bool _permissionDenied = false;
  bool _recording = false;
  StreamSubscription<PitchResult>? _sub;

  // Live tuner
  double? _currentFreq;
  double _currentRms = 0;
  NoteFromFrequency? _currentNote;

  // Recording
  final List<Note> _recordedNotes = [];
  final Set<int> _uniqueMidi = {};
  Duration _recordDuration = Duration.zero;
  Timer? _recordTimer;
  DateTime? _recordStart;
  int? _lastAddedMidi;
  DateTime? _lastAddedTime;

  List<KeyCandidate> _keyCandidates = [];
  VoiceRange? _detectedVoice;

  @override
  void dispose() {
    _sub?.cancel();
    _recordTimer?.cancel();
    _mic.dispose();
    super.dispose();
  }

  Future<void> _toggleListen() async {
    if (_listening) {
      await _stopMic();
    } else {
      await _startMic();
    }
  }

  Future<void> _startMic() async {
    try {
      await _mic.start();
      setState(() {
        _listening = true;
        _permissionDenied = false;
      });
      _sub = _mic.pitchStream.listen(_onPitch);
    } catch (_) {
      setState(() {
        _permissionDenied = true;
        _listening = false;
      });
    }
  }

  Future<void> _stopMic() async {
    await _sub?.cancel();
    _sub = null;
    await _mic.stop();
    _recordTimer?.cancel();
    _recordTimer = null;
    _recording = false;
    setState(() {
      _listening = false;
      _currentFreq = null;
      _currentNote = null;
      _currentRms = 0;
    });
  }

  void _onPitch(PitchResult result) {
    final smoothed = _smoother.add(result.frequency);

    NoteFromFrequency? note;
    if (smoothed != null && smoothed > 0) {
      note = frequencyToNote(smoothed);
    }

    setState(() {
      _currentFreq = smoothed;
      _currentNote = note;
      _currentRms = result.rms;
    });

    // Накопление нот при записи
    if (_recording && note != null && result.rms > 0.02) {
      // Только если попадание в ноту (не глиссандо)
      if (note.cents.abs() < 35) {
        final now = DateTime.now();
        final isDuplicate = _lastAddedMidi == note.midi &&
            _lastAddedTime != null &&
            now.difference(_lastAddedTime!).inMilliseconds < 300;

        if (!isDuplicate) {
          _recordedNotes.add(Note(note.midi));
          _uniqueMidi.add(note.midi);
          _lastAddedMidi = note.midi;
          _lastAddedTime = now;
        }
      }
    }
  }

  void _startRecording() {
    _resetAnalysis();
    setState(() => _recording = true);
    if (!_listening) _startMic();
    _recordStart = DateTime.now();
    _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_recordStart != null && mounted) {
        setState(() {
          _recordDuration = DateTime.now().difference(_recordStart!);
        });
      }
    });
  }

  void _stopRecording() {
    _recordTimer?.cancel();
    _recordTimer = null;
    setState(() => _recording = false);

    final candidates = detectKeys(_recordedNotes);
    final voice = _detectVoiceType(_uniqueMidi);

    setState(() {
      _keyCandidates = candidates;
      _detectedVoice = voice;
    });
  }

  VoiceRange? _detectVoiceType(Set<int> midis) {
    if (midis.length < 3) return null;

    final avgMidi = midis.reduce((a, b) => a + b) / midis.length;
    final isMale = avgMidi < 57; // ниже A3 — мужской

    final candidates = voiceRanges.where(
      (v) => v.gender == (isMale ? VoiceGender.male : VoiceGender.female),
    );

    VoiceRange? best;
    int bestScore = -1;
    for (final v in candidates) {
      int score = 0;
      for (final m in midis) {
        if (m >= v.minMidi && m <= v.maxMidi) score++;
      }
      if (score > bestScore) {
        bestScore = score;
        best = v;
      }
    }
    return best;
  }

  void _resetAnalysis() {
    setState(() {
      _recordedNotes.clear();
      _uniqueMidi.clear();
      _keyCandidates = [];
      _detectedVoice = null;
      _recordDuration = Duration.zero;
      _lastAddedMidi = null;
      _lastAddedTime = null;
    });
    _recordStart = null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Тюнер и анализ голоса')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildModeSelector(),
            const SizedBox(height: 12),
            if (_permissionDenied) _buildPermissionWarning(),
            _buildLiveDisplay(),
            const SizedBox(height: 12),
            if (_mode == TunerMode.record) ...[
              _buildRecordControls(),
              const SizedBox(height: 12),
              _buildAnalysisResults(),
            ],
            const SizedBox(height: 12),
            _buildListenButton(),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  // -------- UI --------

  Widget _buildModeSelector() {
    return SegmentedButton<TunerMode>(
      segments: const [
        ButtonSegment(
            value: TunerMode.tuner,
            label: Text('Тюнер'),
            icon: Icon(Icons.graphic_eq)),
        ButtonSegment(
            value: TunerMode.record,
            label: Text('Запись'),
            icon: Icon(Icons.mic)),
      ],
      selected: {_mode},
      onSelectionChanged: (s) {
        setState(() => _mode = s.first);
        if (_mode == TunerMode.tuner) {
          _stopRecording();
        }
      },
    );
  }

  Widget _buildPermissionWarning() {
    return Card(
      color: Colors.red[50],
      child: const Padding(
        padding: EdgeInsets.all(12),
        child: Text(
          'Нет доступа к микрофону. Разрешите доступ в настройках '
          'приложения и попробуйте снова.',
          style: TextStyle(color: Colors.red),
        ),
      ),
    );
  }

  Widget _buildLiveDisplay() {
    final note = _currentNote;
    final freq = _currentFreq;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Название ноты и частота
            if (note != null) ...[
              Text(
                note.name(latinNames),
                style: const TextStyle(
                    fontSize: 56,
                    fontWeight: FontWeight.bold,
                    height: 1.1),
              ),
              Text(
                '${note.frequency.toStringAsFixed(1)} Hz',
                style: TextStyle(
                    fontSize: 16, color: Colors.grey[700]),
              ),
              const SizedBox(height: 4),
              Text(
                Note(note.midi).germanName,
                style: TextStyle(
                    fontSize: 14, color: Colors.grey[500]),
              ),
            ] else ...[
              Text(
                _listening ? '—' : '···',
                style: const TextStyle(
                    fontSize: 56,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey,
                    height: 1.1),
              ),
              Text(
                _listening ? 'Слушаю...' : 'Нажмите «Начать»',
                style: TextStyle(
                    fontSize: 14, color: Colors.grey[600]),
              ),
            ],
            const SizedBox(height: 16),
            // Стрелка отклонения
            _TunerArrow(cents: note?.cents ?? 0, active: note != null),
            const SizedBox(height: 8),
            // Индикатор громкости
            _VolumeBar(rms: _currentRms),
          ],
        ),
      ),
    );
  }

  Widget _buildRecordControls() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Длительность: ${_formatDuration(_recordDuration)}',
                  style: const TextStyle(fontSize: 14),
                ),
                Text(
                  'Нот: ${_recordedNotes.length}',
                  style: const TextStyle(fontSize: 14),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (!_recording)
              FilledButton.icon(
                onPressed: _startRecording,
                icon: const Icon(Icons.fiber_manual_record),
                label: const Text('Записать'),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.red,
                ),
              )
            else
              FilledButton.icon(
                onPressed: _stopRecording,
                icon: const Icon(Icons.stop),
                label: const Text('Стоп и анализ'),
              ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _resetAnalysis,
              icon: const Icon(Icons.refresh),
              label: const Text('Сбросить'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAnalysisResults() {
    if (_detectedVoice == null && _keyCandidates.isEmpty) {
      return const SizedBox.shrink();
    }

    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_detectedVoice != null) ...[
              Text('Тип голоса',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                '${_detectedVoice!.label} '
                '(${Note(_detectedVoice!.minMidi).latinName} — '
                '${Note(_detectedVoice!.maxMidi).latinName})',
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const Divider(),
            ],
            if (_keyCandidates.isNotEmpty) ...[
              Text('Вероятные тональности',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              ..._keyCandidates.map((c) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      mainAxisAlignment:
                          MainAxisAlignment.spaceBetween,
                      children: [
                        Text(c.scale.name),
                        Text(
                          '${(c.score * 100).toStringAsFixed(0)}%',
                          style: TextStyle(
                              color: Colors.grey[700]),
                        ),
                      ],
                    ),
                  )),
            ] else if (_detectedVoice == null) ...[
              const Text('Недостаточно данных для анализа. '
                  'Спойте больше нот.'),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildListenButton() {
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: _mode == TunerMode.record ? null : _toggleListen,
        icon: Icon(_listening ? Icons.stop : Icons.mic),
        label: Text(_listening ? 'Остановить' : 'Начать'),
      ),
    );
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

/// Горизонтальная шкала со стрелкой отклонения в центах.
class _TunerArrow extends StatelessWidget {
  final double cents; // -50..+50
  final bool active;

  const _TunerArrow({required this.cents, required this.active});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        // Положение маркера: центрируется при 0 центов
        final clamped = cents.clamp(-50.0, 50.0);
        final position = (clamped + 50) / 100 * width;
        final inTune = cents.abs() < 10;

        return SizedBox(
          height: 60,
          child: Stack(
            children: [
              // Фон-шкала
              Positioned(
                top: 30,
                left: 0,
                right: 0,
                child: Container(
                  height: 4,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Colors.red[400]!,
                        Colors.orange[300]!,
                        Colors.green[400]!,
                        Colors.green[400]!,
                        Colors.orange[300]!,
                        Colors.red[400]!,
                      ],
                      stops: const [0.0, 0.3, 0.45, 0.55, 0.7, 1.0],
                    ),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              // Деления -50, -25, 0, +25, +50
              ...[-50, -25, 0, 25, 50].map((tick) {
                final pos = (tick + 50) / 100 * width;
                return Positioned(
                  left: pos - 1,
                  top: tick == 0 ? 20 : 26,
                  child: Container(
                    width: 2,
                    height: tick == 0 ? 18 : 12,
                    color: Colors.black45,
                  ),
                );
              }),
              // Стрелка (треугольник, указывающий вниз)
              if (active)
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 80),
                  left: position - 8,
                  top: 0,
                  child: CustomPaint(
                    size: const Size(16, 20),
                    painter: _ArrowPainter(
                      color: inTune
                          ? Colors.green[700]!
                          : Colors.deepOrange,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _ArrowPainter extends CustomPainter {
  final Color color;
  _ArrowPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final path = Path()
      ..moveTo(size.width / 2, size.height)
      ..lineTo(0, 0)
      ..lineTo(size.width, 0)
      ..close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _ArrowPainter old) =>
      old.color != color;
}

/// Индикатор громкости.
class _VolumeBar extends StatelessWidget {
  final double rms;
  const _VolumeBar({required this.rms});

  @override
  Widget build(BuildContext context) {
    final level = (rms * 10).clamp(0.0, 1.0);
    return Row(
      children: [
        const Icon(Icons.volume_up, size: 16, color: Colors.grey),
        const SizedBox(width: 6),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: level,
              minHeight: 6,
              backgroundColor: Colors.grey[300],
              valueColor: AlwaysStoppedAnimation(
                level > 0.1 ? Colors.green : Colors.grey,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
