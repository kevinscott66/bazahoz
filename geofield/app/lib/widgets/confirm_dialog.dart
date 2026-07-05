import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Подтверждение опасного действия. Возвращает true только при явном
/// подтверждении (закрытие шторкой/back — отказ).
Future<bool> confirmDelete(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Удалить',
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      backgroundColor: GfColors.surfaceHi,
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена')),
        TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: GfColors.error),
            child: Text(confirmLabel)),
      ],
    ),
  );
  return ok == true;
}
