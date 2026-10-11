import 'package:flutter/material.dart';
import 'music_theory.dart';

/// Виртуальная клавиатура. Диапазон задаётся в MIDI.
class PianoKeyboard extends StatelessWidget {
  final int startMidi;
  final int endMidi;
  final Set<int> pressed;
  final void Function(Note note) onTap;

  const PianoKeyboard({
    super.key,
    required this.startMidi,
    required this.endMidi,
    required this.onTap,
    this.pressed = const {},
  });

  static const _blackPcs = {1, 3, 6, 8, 10};

  bool _isBlack(int midi) => _blackPcs.contains(midi % 12);

  @override
  Widget build(BuildContext context) {
    final notes = List.generate(
      endMidi - startMidi + 1,
      (i) => startMidi + i,
    );
    final whites = notes.where((m) => !_isBlack(m)).toList();

    return LayoutBuilder(
      builder: (context, constraints) {
        final keyWidth = constraints.maxWidth / whites.length;
        return SizedBox(
          height: 110,
          child: Stack(
            children: [
              // Белые клавиши
              Row(
                children: whites.map((m) {
                  final note = Note(m);
                  final isActive = pressed.contains(m);
                  return GestureDetector(
                    onTap: () => onTap(note),
                    child: Container(
                      width: keyWidth,
                      decoration: BoxDecoration(
                        color: isActive
                            ? Colors.orange[200]
                            : Colors.white,
                        border: Border.all(color: Colors.black54),
                        borderRadius: const BorderRadius.vertical(
                            bottom: Radius.circular(4)),
                      ),
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            note.latinName,
                            style: const TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: Colors.black87),
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
              // Чёрные клавиши
              ...whites.asMap().entries.expand((entry) {
                final idx = entry.key;
                final m = entry.value;
                final blackMidi = m + 1;
                if (blackMidi > endMidi || !_isBlack(blackMidi)) {
                  return <Widget>[];
                }
                final isActive = pressed.contains(blackMidi);
                return [
                  Positioned(
                    left: keyWidth * (idx + 1) - keyWidth * 0.30,
                    top: 0,
                    child: GestureDetector(
                      onTap: () => onTap(Note(blackMidi)),
                      child: Container(
                        width: keyWidth * 0.60,
                        height: 70,
                        decoration: BoxDecoration(
                          color: isActive
                              ? Colors.deepOrange[400]
                              : Colors.black,
                          borderRadius: const BorderRadius.vertical(
                              bottom: Radius.circular(3)),
                        ),
                        alignment: Alignment.bottomCenter,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            Note(blackMidi).latinName,
                            style: const TextStyle(
                                fontSize: 9,
                                color: Colors.white70),
                          ),
                        ),
                      ),
                    ),
                  ),
                ];
              }),
            ],
          ),
        );
      },
    );
  }
}
