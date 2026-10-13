import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'chroma_analyzer.dart';
import 'fft.dart';
import 'key_detector.dart';
import 'music_theory.dart';

// ============================================================
//  TOP-LEVEL ФУНКЦИЯ ДЛЯ COMPUTE (изолят)
// ============================================================

Map<String, dynamic> _analyzeBytes(Uint8List bytes) {
  final wav = parseWav(bytes);
  if (wav == null) {
    return {
      'error': 'Не удалось прочитать WAV. Поддерживаются PCM 16/24/32-bit '
          'и IEEE float 32-bit.'
    };
  }
  final result = analyzeWav(wav);
  return {
    'chroma': result.chroma,
    'keys': result.keyCandidates
        .map((c) => {
              'tonic': c.scale.tonicPc,
              'typeIndex': c.scale.type.index,
              'score': c.score,
            })
        .toList(),
    'durationMs': result.duration.inMilliseconds,
    'frameCount': result.frameCount,
    'lowestFreq': result.lowestFreq,
    'highestFreq': result.highestFreq,
    'lowestMidi': result.lowestMidi,
    'highestMidi': result.highestMidi,
    'voiceLabel': result.detectedVoice?.label,
  };
}

// ============================================================
//  ЭКРАН
// ============================================================

class FileAnalysisScreen extends StatefulWidget {
  const FileAnalysisScreen({super.key});
  @override
  State<FileAnalysisScreen> createState() => _FileAnalysisScreenState();
}

class _FileAnalysisScreenState extends State<FileAnalysisScreen> {
  final AudioPlayer _player = AudioPlayer();

  String? _fileName;
  String? _filePath;
  int? _fileSize;

  bool _analyzing = false;
  bool _dragging = false;
  String? _error;

  List<double>? _chroma;
  List<KeyCandidate>? _keys;
  Duration? _duration;
  int? _frameCount;
  double? _lowestFreq;
  double? _highestFreq;
  int? _lowestMidi;
  int? _highestMidi;
  String? _voiceLabel;

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  // -------- Запуск анализа --------

  Future<void> _runAnalysis(
    Uint8List bytes,
    String name,
    String? path,
    int size,
  ) async {
    setState(() {
      _error = null;
      _analyzing = true;
      _fileName = name;
      _filePath = path;
      _fileSize = size;
      _chroma = null;
      _keys = null;
      _duration = null;
      _frameCount = null;
      _lowestFreq = null;
      _highestFreq = null;
      _lowestMidi = null;
      _highestMidi = null;
      _voiceLabel = null;
    });

    try {
      final res = await compute(_analyzeBytes, bytes);
      if (!mounted) return;

      if (res['error'] != null) {
        setState(() {
          _error = res['error'] as String;
          _analyzing = false;
        });
        return;
      }

      final chroma = (res['chroma'] as List).cast<double>();
      final keysRaw = (res['keys'] as List).cast<Map>();
      final keys = keysRaw.map((m) {
        final tonic = m['tonic'] as int;
        final typeIndex = m['typeIndex'] as int;
        final score = (m['score'] as num).toDouble();
        return KeyCandidate(
          Scale(tonic, ScaleType.values[typeIndex]),
          score,
        );
      }).toList();

      setState(() {
        _chroma = chroma;
        _keys = keys;
        _duration = Duration(milliseconds: res['durationMs'] as int);
        _frameCount = res['frameCount'] as int;
        _lowestFreq = res['lowestFreq'] as double?;
        _highestFreq = res['highestFreq'] as double?;
        _lowestMidi = res['lowestMidi'] as int?;
        _highestMidi = res['highestMidi'] as int?;
        _voiceLabel = res['voiceLabel'] as String?;
        _analyzing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Ошибка: $e';
        _analyzing = false;
      });
    }
  }

  Future<void> _pickAndAnalyze() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['wav'],
        withData: true,
      );

      if (result == null || result.files.isEmpty) return;

      final picked = result.files.single;
      final bytes = picked.bytes;
      if (bytes == null) {
        setState(() => _error = 'Не удалось прочитать файл');
        return;
      }

      await _runAnalysis(bytes, picked.name, picked.path, picked.size);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Ошибка: $e');
    }
  }

  Future<void> _handleDrop(DropDoneDetails details) async {
    if (details.files.isEmpty) return;
    final file = details.files.first;
    final path = file.path;

    if (!path.toLowerCase().endsWith('.wav')) {
      setState(() => _error = 'Поддерживаются только WAV-файлы');
      return;
    }

    try {
      final bytes = await File(path).readAsBytes();
      await _runAnalysis(bytes, file.name, path, bytes.length);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Не удалось прочитать файл: $e');
    }
  }

  Future<void> _playFile() async {
    if (_filePath == null) return;
    try {
      await _player.stop();
      await _player.play(DeviceFileSource(_filePath!));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось воспроизвести: $e')),
      );
    }
  }

  Future<void> _stopFile() async {
    await _player.stop();
  }

  // -------- UI --------

  @override
  Widget build(BuildContext context) {
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (details) {
        setState(() => _dragging = false);
        _handleDrop(details);
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Анализ аудиофайла')),
        body: Stack(
          children: [
            SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildFileCard(),
                  const SizedBox(height: 10),
                  if (_analyzing) _buildProgress(),
                  if (_error != null) _buildError(),
                  if (_chroma != null) ...[
                    _buildChromaCard(),
                    const SizedBox(height: 10),
                    _buildKeysCard(),
                    const SizedBox(height: 10),
                    _buildRangeCard(),
                  ],
                  const SizedBox(height: 20),
                ],
              ),
            ),
            if (_dragging) _buildDropOverlay(),
          ],
        ),
      ),
    );
  }

  Widget _buildDropOverlay() {
    return Positioned.fill(
      child: IgnorePointer(
        child: Container(
          color: Colors.deepOrange.withValues(alpha: 0.15),
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 24, vertical: 16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Colors.deepOrange,
                  width: 2,
                ),
              ),
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.download,
                      size: 48, color: Colors.deepOrange),
                  SizedBox(height: 8),
                  Text(
                    'Отпустите WAV-файл здесь',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFileCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('WAV-файл',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Поддерживаются PCM 16/24/32-bit и IEEE float 32-bit. '
              'Стерео и многоканал микшируются в моно.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            if (_fileName != null) ...[
              Row(
                children: [
                  const Icon(Icons.audiotrack, size: 18),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _fileName!,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              if (_fileSize != null)
                Text(
                  '${(_fileSize! / 1024 / 1024).toStringAsFixed(2)} MB',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              const SizedBox(height: 6),
              Row(
                children: [
                  IconButton.filledTonal(
                    onPressed: _playFile,
                    icon: const Icon(Icons.play_arrow),
                    tooltip: 'Воспроизвести',
                  ),
                  const SizedBox(width: 6),
                  IconButton.filledTonal(
                    onPressed: _stopFile,
                    icon: const Icon(Icons.stop),
                    tooltip: 'Стоп',
                  ),
                ],
              ),
              const Divider(),
            ],
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _analyzing ? null : _pickAndAnalyze,
                icon: const Icon(Icons.upload_file),
                label: Text(_analyzing
                    ? 'Анализ...'
                    : 'Выбрать WAV-файл и анализировать'),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'На Windows можно перетащить WAV-файл прямо в окно.',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProgress() {
    return const Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('Анализирую аудио... Это может занять 5–30 секунд, '
                'в зависимости от длины файла.'),
          ],
        ),
      ),
    );
  }

  Widget _buildError() {
    return Card(
      color: Colors.red[50],
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          _error!,
          style: const TextStyle(color: Colors.red),
        ),
      ),
    );
  }

  Widget _buildChromaCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Хромаграмма',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Насколько каждая из 12 нот присутствует в записи. '
              'Нормировано 0..1.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 160,
              child: _ChromaChart(chroma: _chroma!),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildKeysCard() {
    final keys = _keys!;
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Вероятные тональности',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ...keys.asMap().entries.map((entry) {
              final i = entry.key;
              final k = entry.value;
              final pct = (k.score * 100).clamp(0, 100);
              final isTop = i == 0;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    SizedBox(
                      width: 30,
                      child: Text(
                        '#${i + 1}',
                        style: TextStyle(
                          color: isTop
                              ? Theme.of(context).colorScheme.primary
                              : Colors.grey,
                          fontWeight: isTop
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        k.scale.name,
                        style: TextStyle(
                          fontSize: isTop ? 18 : 15,
                          fontWeight: isTop
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                    ),
                    Text('${pct.toStringAsFixed(0)}%'),
                  ],
                ),
              );
            }),
            const SizedBox(height: 8),
            Text(
              'Оценка основана на алгоритме Крамхансля-Шмуклера: '
              'сравнение хромаграммы с эталонными профилями мажора и минора.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRangeCard() {
    if (_voiceLabel == null &&
        _lowestFreq == null &&
        _frameCount == null) {
      return const SizedBox.shrink();
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Дополнительно',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (_duration != null)
              _infoRow('Длительность', _formatDuration(_duration!)),
            if (_frameCount != null)
              _infoRow('Обработано кадров', '$_frameCount'),
            if (_voiceLabel != null)
              _infoRow('Предполагаемый голос', _voiceLabel!),
            if (_lowestFreq != null &&
                _highestFreq != null &&
                _lowestMidi != null &&
                _highestMidi != null) ...[
              _infoRow(
                'Оценочный диапазон',
                '${Note(_lowestMidi!).latinName} – '
                    '${Note(_highestMidi!).latinName} '
                    '(${_lowestFreq!.toStringAsFixed(0)}–'
                    '${_highestFreq!.toStringAsFixed(0)} Гц)',
              ),
              Text(
                'Диапазон определяется по 10–90 процентилю реальных '
                'f0 в записи. Показывается только для сольного '
                'вокала (при полифонии не выводится).',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: Colors.grey),
            ),
          ),
          Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

// ============================================================
//  ГИСТОГРАММА ХРОМАГРАММЫ
// ============================================================

class _ChromaChart extends StatelessWidget {
  final List<double> chroma;
  const _ChromaChart({required this.chroma});

  @override
  Widget build(BuildContext context) {
    final maxVal =
        chroma.reduce((a, b) => a > b ? a : b).clamp(0.0001, 1e9);

    return LayoutBuilder(
      builder: (context, constraints) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: List.generate(12, (i) {
            final value = chroma[i] / maxVal;
            final isBlack = const {1, 3, 6, 8, 10}.contains(i);
            return Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text(
                      chroma[i].toStringAsFixed(2),
                      style: const TextStyle(fontSize: 9),
                    ),
                    const SizedBox(height: 2),
                    Container(
                      height: 90 * value + 4,
                      decoration: BoxDecoration(
                        color: isBlack
                            ? Colors.deepOrange[400]
                            : Colors.deepOrange[200],
                        borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(3)),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      latinNames[i],
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: isBlack
                            ? Colors.black87
                            : Colors.grey[700],
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
        );
      },
    );
  }
}
