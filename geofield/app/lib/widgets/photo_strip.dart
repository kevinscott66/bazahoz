import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../data/photo_repository.dart';
import '../models/photo.dart';
import '../theme/tokens.dart';
import 'confirm_dialog.dart';

/// Выбор снимка: true — камера, false — галерея. Возвращает путь к файлу
/// или null (отмена). Интерфейс-функция: тесты подставляют свой файл,
/// не трогая платформенные каналы image_picker.
typedef PhotoPicker = Future<String?> Function(bool camera);

Future<String?> _defaultPicker(bool camera) async {
  final x = await ImagePicker().pickImage(
    source: camera ? ImageSource.camera : ImageSource.gallery,
    // Полевое фото: 2560px и q85 достаточно для документации, а вес файла
    // на порядок меньше оригинала (бюджет памяти устройства, ТЗ §10).
    maxWidth: 2560,
    imageQuality: 85,
  );
  return x?.path;
}

/// Лента фото сущности (ТЗ §6.6): миниатюры + «+ Фото» (камера/галерея).
/// Тап по миниатюре — просмотр с удалением.
class PhotoStrip extends StatefulWidget {
  const PhotoStrip({
    super.key,
    required this.photos,
    required this.parentType,
    required this.parentId,
    required this.ensureParent,
    this.picker,
  });

  final PhotoRepository photos;
  final String parentType; // 'point' | 'sample'
  final String parentId;

  /// Родитель должен существовать до ребёнка: колбэк дожимает сохранение
  /// формы и возвращает true, если запись в базе.
  final Future<bool> Function() ensureParent;

  /// null — боевой пикер (камера/галерея через image_picker).
  final PhotoPicker? picker;

  @override
  State<PhotoStrip> createState() => _PhotoStripState();
}

class _PhotoStripState extends State<PhotoStrip> {
  List<Photo> _items = const [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final items =
        await widget.photos.listByParent(widget.parentType, widget.parentId);
    if (!mounted) return;
    setState(() => _items = items);
  }

  Future<void> _onAdd() async {
    if (_busy) return;
    final camera = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: GfColors.surfaceHi,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _sheetRow(Icons.photo_camera_outlined, 'Камера',
              () => Navigator.pop(context, true)),
          _sheetRow(Icons.photo_library_outlined, 'Из галереи',
              () => Navigator.pop(context, false)),
        ]),
      ),
    );
    if (camera == null || !mounted) return;

    if (!await widget.ensureParent()) {
      _snack('Сначала сохраните запись (см. подпись у индикатора)');
      return;
    }
    final String? path;
    try {
      path = await (widget.picker ?? _defaultPicker)(camera);
    } catch (e) {
      _snack('Камера недоступна: $e');
      return;
    }
    if (path == null) return; // отменил — не ошибка

    setState(() => _busy = true);
    try {
      await widget.photos.addFromFile(path,
          parentType: widget.parentType, parentId: widget.parentId);
      await _reload();
    } catch (e) {
      _snack('Фото не сохранилось — проверьте память устройства');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _onOpen(Photo photo) async {
    final delete = await showDialog<bool>(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: GfColors.surfaceHi,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 480),
            child: Image.file(File(photo.filePath),
                errorBuilder: (_, __, ___) => const Padding(
                      padding: EdgeInsets.all(GfSpace.x24),
                      child: Text('Файл фото не найден на устройстве',
                          style: GfText.body),
                    )),
          ),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            TextButton.icon(
              onPressed: () => Navigator.pop(context, true),
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('Удалить'),
              style: TextButton.styleFrom(foregroundColor: GfColors.error),
            ),
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Закрыть')),
          ]),
        ]),
      ),
    );
    if (delete != true || !mounted) return;
    final confirmed = await confirmDelete(
      context,
      title: 'Удалить фото?',
      message: 'Запись можно восстановить в камералке до синхронизации.',
    );
    if (!confirmed) return;
    try {
      await widget.photos.softDelete(photo);
      await _reload();
    } catch (e) {
      _snack('Не удалось удалить — проверьте память устройства');
    }
  }

  Widget _sheetRow(IconData icon, String text, VoidCallback onTap) => InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: GfTouch.min),
          padding: const EdgeInsets.symmetric(horizontal: GfSpace.x16),
          alignment: Alignment.centerLeft,
          child: Row(children: [
            Icon(icon, size: 22, color: GfColors.textSecondary),
            const SizedBox(width: GfSpace.x12),
            Text(text, style: GfText.body),
          ]),
        ),
      );

  void _snack(String m) {
    if (!mounted) return;
    context.snack(m);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 96,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final photo in _items)
            Padding(
              padding: const EdgeInsets.only(right: GfSpace.x8),
              child: InkWell(
                borderRadius: BorderRadius.circular(GfRadius.r12),
                onTap: () => _onOpen(photo),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(GfRadius.r12),
                  child: Image.file(
                    File(photo.filePath),
                    width: 96,
                    height: 96,
                    fit: BoxFit.cover,
                    // Миниатюра декодируется уменьшенной — не полный кадр
                    // в памяти на каждую ячейку (бюджет памяти, ТЗ §10).
                    cacheWidth: 256,
                    errorBuilder: (_, __, ___) => Container(
                      width: 96,
                      height: 96,
                      color: GfColors.surface,
                      child: const Icon(Icons.broken_image_outlined,
                          color: GfColors.textFaint),
                    ),
                  ),
                ),
              ),
            ),
          InkWell(
            borderRadius: BorderRadius.circular(GfRadius.r12),
            onTap: _onAdd,
            child: Container(
              width: 96,
              height: 96,
              decoration: gfCard(),
              child: _busy
                  ? const Center(
                      child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: GfColors.accent)))
                  : const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.add_a_photo_outlined,
                            color: GfColors.textSecondary),
                        SizedBox(height: GfSpace.x4),
                        Text('+ Фото', style: GfText.hint),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
