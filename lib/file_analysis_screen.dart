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
