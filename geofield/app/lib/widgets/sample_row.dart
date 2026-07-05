import 'package:flutter/material.dart';

import '../models/sample.dart';
import '../theme/sample_type.dart';
import '../theme/tokens.dart';

/// Строка пробы в списках (форма точки, лаборатория): цветовой маркер типа,
/// моноширинный номер, подпись типа.
class SampleRow extends StatelessWidget {
  const SampleRow(this.sample, {super.key});

  final Sample sample;

  @override
  Widget build(BuildContext context) {
    final t = SampleType.fromCode(sample.sampleType);
    return Padding(
      padding: const EdgeInsets.only(bottom: GfSpace.x8),
      child: Row(children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: t.color, shape: BoxShape.circle),
        ),
        const SizedBox(width: GfSpace.x8),
        Text(sample.sampleNumber, style: GfText.numberSmall),
        const SizedBox(width: GfSpace.x8),
        Expanded(child: Text(t.label, style: GfText.hint)),
      ]),
    );
  }
}
