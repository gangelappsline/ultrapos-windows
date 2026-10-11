import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/errors/app_failure.dart';
import '../../../../core/providers.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/ui/app_widgets.dart';

/// Gestión de categorías del catálogo.
///
/// Las categorías sirven para dos cosas muy concretas en una tienda: filtrar el
/// catálogo en la pantalla de venta y agrupar los reportes. Se pide un color
/// porque el color se reutiliza en los chips de venta y en los gráficos, lo que
/// da coherencia visual sin trabajo extra.
class CategoryManagerDialog extends ConsumerStatefulWidget {
  const CategoryManagerDialog({super.key});

  static Future<void> show(BuildContext context) => showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext context) => const CategoryManagerDialog(),
      );

  @override
  ConsumerState<CategoryManagerDialog> createState() => _CategoryManagerDialogState();
}

class _CategoryManagerDialogState extends ConsumerState<CategoryManagerDialog> {
  final TextEditingController _name = TextEditingController();
  String _color = '#00AEEF';

  static const List<String> _palette = <String>[
    '#0A2A4A',
    '#00AEEF',
    '#FF6B00',
    '#E53935',
    '#2E7D32',
    '#6A1B9A',
    '#00838F',
    '#616161',
  ];

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<Category>> categories = ref.watch(categoriesProvider);

    return AlertDialog(
      contentPadding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      title: const Row(
        children: <Widget>[
          Icon(Icons.category_outlined, color: AppColors.deepBlue, size: 22),
          SizedBox(width: AppSpacing.sm),
          Text('Categorías'),
        ],
      ),
      content: SizedBox(
        width: 620,
        height: 420,
        child: Column(
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _name,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: 'Nueva categoría',
                      hintText: 'Bebidas, Abarrotes, Limpieza…',
                    ),
                    onSubmitted: (_) => _create(),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Row(
                  children: <Widget>[
                    for (final String color in _palette)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: GestureDetector(
                          onTap: () => setState(() => _color = color),
                          child: Container(
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              color: _hexToColor(color),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: _color == color
                                    ? AppColors.deepBlue
                                    : Colors.transparent,
                                width: 2,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: AppSpacing.sm),
                PrimaryButton(
                  label: 'Agregar',
                  icon: Icons.add,
                  onPressed: _create,
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            const Divider(height: 1),
            Expanded(
              child: categories.when(
                data: (List<Category> list) => list.isEmpty
                    ? const EmptyState(
                        title: 'Sin categorías',
                        message: 'Cree categorías para organizar el catálogo y los reportes.',
                        icon: Icons.category_outlined,
                      )
                    : ListView.separated(
                        itemCount: list.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (BuildContext context, int index) {
                          final Category category = list[index];
                          return ListTile(
                            dense: true,
                            leading: Container(
                              width: 14,
                              height: 14,
                              decoration: BoxDecoration(
                                color: _hexToColor(category.colorHex ?? '#00AEEF'),
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                            title: Text(category.name),
                            subtitle: Text(
                              category.isActive ? 'Activa' : 'Inactiva',
                              style: AppTypography.caption,
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                IconButton(
                                  tooltip: 'Renombrar',
                                  iconSize: 16,
                                  onPressed: () => _rename(category),
                                  icon: const Icon(Icons.edit_outlined),
                                ),
                                IconButton(
                                  tooltip: category.isActive ? 'Desactivar' : 'Reactivar',
                                  iconSize: 16,
                                  onPressed: () => _toggle(category),
                                  icon: Icon(
                                    category.isActive
                                        ? Icons.visibility_off_outlined
                                        : Icons.visibility_outlined,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                error: (Object error, _) => ErrorState(message: '$error'),
                loading: () => const LoadingState(),
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cerrar'),
        ),
      ],
    );
  }

  Future<void> _create() async {
    final String name = _name.text.trim();
    if (name.isEmpty) {
      AppSnack.warning(context, 'Escriba el nombre de la categoría.');
      return;
    }
    try {
      await ref
          .read(appDatabaseProvider)
          .productsDao
          .createCategory(name: name, colorHex: _color);
      _name.clear();
      ref.invalidate(categoriesProvider);
      if (mounted) AppSnack.success(context, 'Categoría "$name" creada.');
    } on AppFailure catch (failure) {
      if (mounted) AppSnack.error(context, failure.message);
    }
  }

  Future<void> _rename(Category category) async {
    final TextEditingController controller = TextEditingController(text: category.name);
    final NameEdit? edit = await showDialog<NameEdit>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Renombrar categoría'),
        content: SizedBox(
          width: 380,
          child: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Nombre'),
            onSubmitted: (String value) => Navigator.of(context).pop(
              NameEdit(name: value, colorHex: category.colorHex),
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(
              NameEdit(name: controller.text, colorHex: category.colorHex),
            ),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.orange),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (edit == null || edit.name.trim().isEmpty || !mounted) return;

    await ref.read(appDatabaseProvider).productsDao.updateCategory(
          category: category,
          name: edit.name.trim(),
        );
    ref.invalidate(categoriesProvider);
  }

  Future<void> _toggle(Category category) async {
    await ref.read(appDatabaseProvider).productsDao.updateCategory(
          category: category,
          isActive: !category.isActive,
        );
    ref.invalidate(categoriesProvider);
  }

  static Color _hexToColor(String hex) {
    final String clean = hex.replaceAll('#', '');
    final int value = int.tryParse(clean, radix: 16) ?? 0x00AEEF;
    return Color(clean.length == 8 ? value : 0xFF000000 | value);
  }
}

/// Resultado de renombrar (nombre + color conservado).
@immutable
class NameEdit {
  const NameEdit({required this.name, this.colorHex});

  final String name;
  final String? colorHex;
}
