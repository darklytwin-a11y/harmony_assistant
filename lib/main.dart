import 'package:flutter/material.dart';

import 'music_theory.dart';
import 'key_detector.dart';
import 'audio_service.dart';
import 'piano_keyboard.dart';
import 'tuner_screen.dart';

void main() => runApp(const HarmonyApp());

class HarmonyApp extends StatelessWidget {
  const HarmonyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Harmony Assistant',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepOrange),
        useMaterial3: true,
      ),
      home: const RootScreen(),
    );
  }
}

class RootScreen extends StatefulWidget {
  const RootScreen({super.key});
  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> {
  int _index = 0;

  static const _pages = [
    HarmonyScreen(),
    TunerScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.piano),
            label: 'Гармония',
          ),
          NavigationDestination(
            icon: Icon(Icons.mic),
            label: 'Тюнер',
          ),
        ],
      ),
    );
  }
}

class HarmonyScreen extends StatefulWidget {
  const HarmonyScreen({super.key});
  @override
  State<HarmonyScreen> createState() => _HarmonyScreenState();
}

class _HarmonyScreenState extends State<HarmonyScreen> {
  final AudioService _audio = AudioService();

  int _tonicPc = 6; // F#
  ScaleType _scaleType = ScaleType.naturalMinor;
  double _a4 = 440.0;

  Note _sourceNote = const Note(64); // E4
  int _direction = 1;
  int _voiceCount = 1;
  final List<int> _intervalSteps = [2, 4, 5, 6];

  VoiceRange _voiceRange = voiceRanges[0];

  final List<Note> _playedHistory = [];
  List<KeyCandidate> _keyCandidates = [];

  final Set<int> _pressedMidi = {};

  Scale get _scale => Scale(_tonicPc, _scaleType);

  @override
  void dispose() {
    _audio.dispose();
    super.dispose();
  }

  List<HarmonyVoice> _calculateHarmony() {
    final results = <HarmonyVoice>[];
    for (int i = 0; i < _voiceCount; i++) {
      final steps = _intervalSteps[i] * _direction;
      final note = _scale.harmony(_sourceNote, steps.abs(), _direction);
      if (note == null) {
        results.add(HarmonyVoice(
          _sourceNote,
          false,
          ['Нота отсутствует в ладу'],
        ));
        continue;
      }

      Note adjusted = note;
      if (_voiceRange.gender == VoiceGender.male) {
        adjusted = Note(adjusted.midi - 12);
      }

      final inRange = adjusted.midi >= _voiceRange.minMidi &&
          adjusted.midi <= _voiceRange.maxMidi;

      final warnings = <String>[];
      if (!inRange) {
        warnings.add('Вне диапазона ${_voiceRange.label}');
      }
      if (_intervalSteps[i] == 4 && i > 0) {
        warnings.add('Проверьте голосоведение');
      }

      results.add(HarmonyVoice(adjusted, inRange, warnings));
    }
    return results;
  }

  Future<void> _playSource() async {
    await _audio.playFrequencies([_sourceNote.frequency(_a4)]);
  }

  Future<void> _playHarmony() async {
    final harmony = _calculateHarmony();
    final freqs = <double>[_sourceNote.frequency(_a4)];
    for (final v in harmony) {
      freqs.add(v.note.frequency(_a4));
    }
    await _audio.playFrequencies(freqs);
  }

  Future<void> _playSingle(HarmonyVoice v) async {
    await _audio.playFrequencies([v.note.frequency(_a4)]);
  }

  void _onKeyTapped(Note n) async {
    setState(() {
      _sourceNote = n;
      _playedHistory.add(n);
      if (_playedHistory.length > 12) _playedHistory.removeAt(0);
      _pressedMidi
        ..clear()
        ..add(n.midi);
    });
    await _audio.playFrequencies([n.frequency(_a4)]);
    await Future.delayed(const Duration(milliseconds: 300));
    if (mounted) {
      setState(() => _pressedMidi.clear());
    }
  }

  void _detectKey() {
    final candidates = detectKeys(_playedHistory);
    setState(() => _keyCandidates = candidates);
    if (candidates.isNotEmpty) {
      final top = candidates.first;
      setState(() {
        _tonicPc = top.scale.tonicPc;
        _scaleType = top.scale.type;
      });
    }
  }

  void _clearHistory() {
    setState(() {
      _playedHistory.clear();
      _keyCandidates = [];
    });
  }

  @override
  Widget build(BuildContext context) {
    final harmony = _calculateHarmony();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Harmony Assistant'),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            onPressed: _showHelp,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildScaleCard(),
            const SizedBox(height: 10),
            _buildVoiceCard(),
            const SizedBox(height: 10),
            _buildInputCard(),
            const SizedBox(height: 10),
            _buildOutputCard(harmony),
            const SizedBox(height: 10),
            _buildKeyDetectCard(),
            const SizedBox(height: 16),
            Text('Клавиатура',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            PianoKeyboard(
              startMidi: 48,
              endMidi: 84,
              pressed: _pressedMidi,
              onTap: _onKeyTapped,
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildScaleCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Лад',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<int>(
                    value: _tonicPc,
                    decoration:
                        const InputDecoration(labelText: 'Тоника'),
                    items: List.generate(12, (i) {
                      return DropdownMenuItem(
                        value: i,
                        child: Text(
                          '${latinNames[i]} (${germanNames[i]})',
                        ),
                      );
                    }),
                    onChanged: (v) =>
                        setState(() => _tonicPc = v ?? _tonicPc),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButtonFormField<ScaleType>(
                    value: _scaleType,
                    decoration:
                        const InputDecoration(labelText: 'Тип'),
                    items: ScaleType.values
                        .map((s) => DropdownMenuItem(
                              value: s,
                              child: Text(s.label),
                            ))
                        .toList(),
                    onChanged: (v) =>
                        setState(() => _scaleType = v ?? _scaleType),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('A4 = '),
                Expanded(
                  child: Slider(
                    value: _a4,
                    min: 415,
                    max: 466,
                    divisions: 51,
                    label: '${_a4.toStringAsFixed(1)} Hz',
                    onChanged: (v) => setState(() => _a4 = v),
                  ),
                ),
                Text('${_a4.toStringAsFixed(0)} Hz'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVoiceCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Голос',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            DropdownButtonFormField<VoiceRange>(
              value: _voiceRange,
              decoration: const InputDecoration(labelText: 'Тип голоса'),
              items: voiceRanges
                  .map((v) => DropdownMenuItem(
                        value: v,
                        child: Text(
                          '${v.label}  '
                          '(${Note(v.minMidi).latinName} — '
                          '${Note(v.maxMidi).latinName})',
                        ),
                      ))
                  .toList(),
              onChanged: (v) =>
                  setState(() => _voiceRange = v ?? _voiceRange),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Исходная нота и интервал',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<int>(
                    value: _sourceNote.midi,
                    isExpanded: true,
                    decoration: const InputDecoration(
                        labelText: 'Исходная нота'),
                    items: List.generate(88 - 21 + 1, (i) {
                      final m = 21 + i;
                      return DropdownMenuItem(
                        value: m,
                        child: Text(
                          '${Note(m).latinName}  '
                          '(${Note(m).germanName})  '
                          '${Note(m).frequency(_a4).toStringAsFixed(1)} Hz',
                          overflow: TextOverflow.ellipsis,
                        ),
                      );
                    }),
                    onChanged: (v) =>
                        setState(() => _sourceNote = Note(v!)),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: _playSource,
                  icon: const Icon(Icons.play_arrow),
                  tooltip: 'Прослушать исходную ноту',
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Text('Направление:'),
                const SizedBox(width: 8),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 1, label: Text('Вверх')),
                    ButtonSegment(value: -1, label: Text('Вниз')),
                  ],
                  selected: {_direction},
                  onSelectionChanged: (s) =>
                      setState(() => _direction = s.first),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('Голосов гармонии:'),
                const SizedBox(width: 8),
                DropdownButton<int>(
                  value: _voiceCount,
                  items: [1, 2, 3, 4]
                      .map((n) => DropdownMenuItem(
                            value: n,
                            child: Text('$n'),
                          ))
                      .toList(),
                  onChanged: (v) =>
                      setState(() => _voiceCount = v ?? 1),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ...List.generate(_voiceCount, (i) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Text('Голос ${i + 1}:'),
                    const SizedBox(width: 8),
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        value: _intervalSteps[i],
                        isExpanded: true,
                        decoration:
                            const InputDecoration(labelText: 'Интервал'),
                        items: const [
                          DropdownMenuItem(
                              value: 0, child: Text('Прима')),
                          DropdownMenuItem(
                              value: 1, child: Text('Секунда')),
                          DropdownMenuItem(
                              value: 2, child: Text('Терция')),
                          DropdownMenuItem(
                              value: 3, child: Text('Кварта')),
                          DropdownMenuItem(
                              value: 4, child: Text('Квинта')),
                          DropdownMenuItem(
                              value: 5, child: Text('Секста')),
                          DropdownMenuItem(
                              value: 6, child: Text('Септима')),
                          DropdownMenuItem(
                              value: 7, child: Text('Октава')),
                        ],
                        onChanged: (v) => setState(
                            () => _intervalSteps[i] = v ?? 0),
                      ),
                    ),
                  ],
                ),
              );
            }),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _playHarmony,
                icon: const Icon(Icons.play_circle),
                label: const Text('Прослушать гармонию'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOutputCard(List<HarmonyVoice> harmony) {
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Результат',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            _resultRow(
              'Исходная',
              _sourceNote.latinName,
              _sourceNote.germanName,
              _sourceNote.frequency(_a4),
              false,
              null,
            ),
            const Divider(),
            ...List.generate(harmony.length, (i) {
              final v = harmony[i];
              return _resultRow(
                'Голос ${i + 1} '
                '(${_intervalLabel(_intervalSteps[i])} '
                '${_direction == 1 ? 'вверх' : 'вниз'})',
                v.latinName,
                v.germanName,
                v.note.frequency(_a4),
                !v.inRange,
                v.warnings,
                onPlay: () => _playSingle(v),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _resultRow(
    String label,
    String latin,
    String german,
    double freq,
    bool warning,
    List<String>? warnings, {
    VoidCallback? onPlay,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(
                        fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 2),
                Text('$latin  ($german)',
                    style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600)),
                Text('${freq.toStringAsFixed(2)} Hz',
                    style: const TextStyle(
                        fontSize: 12, color: Colors.grey)),
                if (warning && warnings != null)
                  ...warnings.map((w) => Text(
                        '! $w',
                        style: const TextStyle(
                            color: Colors.red, fontSize: 11),
                      )),
              ],
            ),
          ),
          if (onPlay != null)
            IconButton(
              icon: const Icon(Icons.volume_up),
              onPressed: onPlay,
              tooltip: 'Прослушать',
            ),
        ],
      ),
    );
  }

  Widget _buildKeyDetectCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Определение тональности',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Сыграйте несколько нот — приложение определит '
              'вероятные тональности.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed:
                        _playedHistory.isEmpty ? null : _detectKey,
                    icon: const Icon(Icons.search),
                    label: const Text('Определить'),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: _clearHistory,
                  icon: const Icon(Icons.clear),
                  tooltip: 'Очистить',
                ),
              ],
            ),
            if (_keyCandidates.isNotEmpty) ...[
              const SizedBox(height: 8),
              ..._keyCandidates.map((c) {
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(c.scale.name),
                  trailing: Text(
                      '${(c.score * 100).toStringAsFixed(0)}%'),
                  onTap: () {
                    setState(() {
                      _tonicPc = c.scale.tonicPc;
                      _scaleType = c.scale.type;
                    });
                  },
                );
              }),
            ],
          ],
        ),
      ),
    );
  }

  String _intervalLabel(int steps) {
    const names = [
      'Прима', 'Секунда', 'Терция', 'Кварта',
      'Квинта', 'Секста', 'Септима', 'Октава'
    ];
    return names[steps.clamp(0, 7)];
  }

  void _showHelp() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Как пользоваться'),
        content: const SingleChildScrollView(
          child: Text(
            '1. Выберите лад (или сыграйте ноты и нажмите '
            '«Определить тональность»).\n\n'
            '2. Выберите тип голоса — учитывается диапазон.\n\n'
            '3. Нажмите нужную клавишу на виртуальной клавиатуре '
            'или выберите ноту из списка.\n\n'
            '4. Задайте интервалы для 1-4 голосов гармонии '
            '(терция, кварта, квинта и т.д.) и направление.\n\n'
            '5. Нажмите «Прослушать гармонию» — прозвучат '
            'исходная нота и гармонические голоса.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Понятно'),
          ),
        ],
      ),
    );
  }
}
