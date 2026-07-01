import 'dart:async';

/// Итог одного сохранения: сохранено / ввод невалиден / запись провалилась.
/// Разделены, чтобы выход с экрана мог уйти при невалидном вводе (сохранять
/// нечего), но НЕ уходил молча при реальном сбое записи валидных данных
/// (ТЗ §0, правило 2).
enum SaveResult { saved, invalid, failed }

/// Очередь сохранений экрана: дебаунс + сериализация.
/// Конкурентные вызовы (автосейв при открытии, «Готово», системная «назад»)
/// выполняются строго по очереди — флаги вроде isNew читаются без гонок.
/// Операция обязана НЕ бросать исключений (возвращать SaveResult.failed).
class SaveQueue {
  SaveQueue({this.debounce = const Duration(milliseconds: 400)});

  final Duration debounce;
  Future<SaveResult> _chain = Future.value(SaveResult.saved);
  Timer? _timer;

  /// Отложенное сохранение после правки поля.
  void schedule(Future<SaveResult> Function() op) {
    _timer?.cancel();
    _timer = Timer(debounce, () {
      flush(op);
    });
  }

  /// Немедленно дожать сохранение (выход с экрана, «Готово»).
  Future<SaveResult> flush(Future<SaveResult> Function() op) {
    _timer?.cancel();
    _chain = _chain.then((_) => op());
    return _chain;
  }

  void dispose() => _timer?.cancel();
}
