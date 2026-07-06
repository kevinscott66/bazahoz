import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Поле-пикер: выглядит как текстовое поле, по тапу — шторка с крупными
/// строками (56px, ТЗ §4.5). Замена дропдауну: мелкое меню неудобно
/// в перчатках, а длинные подписи в нём переполняют строку.
class FieldPicker extends StatelessWidget {
  const FieldPicker({
    super.key,
    required this.label,
    required this.options, // (code, label)
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final List<(String, String)> options;
  final String? selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final current =
        options.where((o) => o.$1 == selected).map((o) => o.$2).firstOrNull;
    return InkWell(
      borderRadius: BorderRadius.circular(GfRadius.r12),
      onTap: () async {
        final code = await showModalBottomSheet<String>(
          context: context,
          backgroundColor: GfColors.surfaceHi,
          builder: (_) => SafeArea(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: GfSpace.x8),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      GfSpace.x16, GfSpace.x8, GfSpace.x16, GfSpace.x8),
                  child: Text(label.toUpperCase(), style: GfText.sectionLabel),
                ),
                for (final (code, text) in options)
                  InkWell(
                    onTap: () => Navigator.pop(context, code),
                    child: Container(
                      constraints: const BoxConstraints(minHeight: GfTouch.min),
                      padding:
                          const EdgeInsets.symmetric(horizontal: GfSpace.x16),
                      alignment: Alignment.centerLeft,
                      child: Row(children: [
                        Expanded(child: Text(text, style: GfText.body)),
                        if (code == selected)
                          Icon(Icons.check,
                              size: 20, color: GfColors.accent),
                      ]),
                    ),
                  ),
              ],
            ),
          ),
        );
        if (code != null) onSelected(code);
      },
      child: InputDecorator(
        decoration: gfInputDecoration(label: label).copyWith(
          suffixIcon:
              Icon(Icons.expand_more, color: GfColors.textSecondary),
        ),
        isEmpty: current == null,
        child: current == null ? null : Text(current, style: GfText.body),
      ),
    );
  }
}
