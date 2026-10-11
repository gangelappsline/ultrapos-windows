import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/domain/enums.dart';
import '../../../../core/errors/app_failure.dart';
import '../../../../core/providers.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/ui/app_widgets.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../core/utils/money.dart';
import '../../../auth/application/session_controller.dart';

/// Alta y edición de productos.
///
/// Un formulario de POS no puede ser una copia de un ERP: aquí solo se piden
/// los datos que cambian una venta (nombre, precio, código de barras, stock).
/// Los márgenes se calculan y se muestran en vivo para que quien fija el precio
/// vea en el momento si se está equivocando.
class ProductFormDialog extends ConsumerStatefulWidget {
  const ProductFormDialog({super.key, this.product});

  final Product? product;

  static Future<bool?> show(BuildContext context, {Product? product}) =>
      showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext context) => ProductFormDialog(product: product),
      );

  @override
  ConsumerState<ProductFormDialog> createState() => _ProductFormDialogState();
}

class _ProductFormDialogState extends ConsumerState<ProductFormDialog> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  late final TextEditingController _name;
  late final TextEditingController _sku;
  late final TextEditingController _barcode;
  late final TextEditingController _price;
  late final TextEditingController _cost;
  late final TextEditingController _stock;
  late final TextEditingController _minStock;
  late final TextEditingController _description;

  int? _categoryId;
  ProductUnit _unit = ProductUnit.unit;
  int _taxRateBps = 1600;
  bool _trackStock = true;
  bool _sellByWeight = false;
  bool _isFavorite = false;

  bool get _isEditing => widget.product != null;

  @override
  void initState() {
    super.initState();
    final Product? p = widget.product;
    _name = TextEditingController(text: p?.name ?? '');
    _sku = TextEditingController(text: p?.sku ?? '');
    _barcode = TextEditingController(text: p?.barcode ?? '');
    _price = TextEditingController(text: p == null ? '' : p.price.units.toStringAsFixed(2));
    _cost = TextEditingController(text: p == null ? '' : p.cost.units.toStringAsFixed(2));
    _stock = TextEditingController(
      text: p == null ? '' : AppFormat.quantityMilli(p.stock.milli),
    );
    _minStock = TextEditingController(
      text: p == null ? '' : AppFormat.quantityMilli(p.minStock.milli),
    );
    _description = TextEditingController(text: p?.description ?? '');
    _categoryId = p?.categoryId;
    _unit = p?.unit ?? ProductUnit.unit;
    _taxRateBps = p?.taxRateBps ?? 1600;
    _trackStock = p?.trackStock ?? true;
    _sellByWeight = p?.sellByWeight ?? false;
    _isFavorite = p?.isFavorite ?? false;
  }

  @override
  void dispose() {
    _name.dispose();
    _sku.dispose();
    _barcode.dispose();
    _price.dispose();
    _cost.dispose();
    _stock.dispose();
    _minStock.dispose();
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<Category>> categories = ref.watch(categoriesProvider);
    final CurrencyFormat currency = ref.watch(currencyFormatProvider);
    final Money price = Money.tryParse(_price.text) ?? Money.zero;
    final Money cost = Money.tryParse(_cost.text) ?? Money.zero;

    return AlertDialog(
      contentPadding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      insetPadding: const EdgeInsets.all(AppSpacing.lg),
      title: Row(
        children: <Widget>[
          Icon(
            _isEditing ? Icons.edit_outlined : Icons.add_box_outlined,
            color: AppColors.deepBlue,
            size: 22,
          ),
          const SizedBox(width: AppSpacing.sm),
          Text(_isEditing ? 'Editar producto' : 'Nuevo producto'),
          const Spacer(),
          if (_isEditing)
            StatusChip(
              label: widget.product!.isActive ? 'Activo' : 'Inactivo',
              color: widget.product!.isActive ? AppColors.success : AppColors.grey500,
            ),
        ],
      ),
      content: SizedBox(
        width: 720,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const SectionLabel('Identificación'),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(
                      flex: 3,
                      child: TextFormField(
                        controller: _name,
                        autofocus: true,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: const InputDecoration(
                          labelText: 'Nombre del producto *',
                          hintText: 'Coca Cola 600 ml',
                        ),
                        validator: (String? value) =>
                            (value ?? '').trim().isEmpty ? 'Escriba el nombre' : null,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      flex: 2,
                      child: TextFormField(
                        controller: _barcode,
                        decoration: const InputDecoration(
                          labelText: 'Código de barras',
                          hintText: 'Escanee o escriba',
                          suffixIcon: Icon(Icons.qr_code_scanner, size: 17),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: TextFormField(
                        controller: _sku,
                        decoration: const InputDecoration(labelText: 'SKU / código interno'),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: categories.maybeWhen(
                        data: (List<Category> list) => DropdownButtonFormField<int?>(
                          initialValue: _categoryId,
                          decoration: const InputDecoration(labelText: 'Categoría'),
                          items: <DropdownMenuItem<int?>>[
                            const DropdownMenuItem<int?>(
                              value: null,
                              child: Text('Sin categoría'),
                            ),
                            for (final Category category in list)
                              DropdownMenuItem<int?>(
                                value: category.id,
                                child: Text(category.name),
                              ),
                          ],
                          onChanged: (int? value) => setState(() => _categoryId = value),
                        ),
                        orElse: () => const SizedBox.shrink(),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: AppSpacing.md),
                const SectionLabel('Precio y costo'),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: _MoneyField(
                        controller: _price,
                        label: 'Precio de venta *',
                        symbol: currency.symbol,
                        onChanged: () => setState(() {}),
                        validator: (String? value) {
                          final Money? parsed = Money.tryParse(value);
                          if (parsed == null || !parsed.isPositive) {
                            return 'Precio inválido';
                          }
                          return null;
                        },
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: _MoneyField(
                        controller: _cost,
                        label: 'Costo (opcional)',
                        symbol: currency.symbol,
                        onChanged: () => setState(() {}),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      flex: 2,
                      child: _MarginPreview(price: price, cost: cost, currency: currency),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: DropdownButtonFormField<ProductUnit>(
                        initialValue: _unit,
                        decoration: const InputDecoration(labelText: 'Unidad de venta'),
                        items: <DropdownMenuItem<ProductUnit>>[
                          for (final ProductUnit unit in ProductUnit.values)
                            DropdownMenuItem<ProductUnit>(
                              value: unit,
                              child: Text(unit.label),
                            ),
                        ],
                        onChanged: (ProductUnit? value) =>
                            setState(() => _unit = value ?? ProductUnit.unit),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        initialValue: _taxRateBps,
                        decoration: const InputDecoration(labelText: 'Impuesto'),
                        items: const <DropdownMenuItem<int>>[
                          DropdownMenuItem<int>(value: 0, child: Text('Exento')),
                          DropdownMenuItem<int>(value: 500, child: Text('5 %')),
                          DropdownMenuItem<int>(value: 1000, child: Text('10 %')),
                          DropdownMenuItem<int>(value: 1500, child: Text('15 %')),
                          DropdownMenuItem<int>(value: 1600, child: Text('16 %')),
                          DropdownMenuItem<int>(value: 1800, child: Text('18 %')),
                          DropdownMenuItem<int>(value: 1900, child: Text('19 %')),
                        ],
                        onChanged: (int? value) => setState(() => _taxRateBps = value ?? 0),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: AppSpacing.md),
                const SectionLabel('Inventario'),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: _QuantityField(
                        controller: _stock,
                        label: _isEditing ? 'Stock actual (solo lectura aquí)' : 'Stock inicial',
                        enabled: !_isEditing,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: _QuantityField(
                        controller: _minStock,
                        label: 'Stock mínimo (alerta)',
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      flex: 2,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          _SwitchRow(
                            label: 'Controlar inventario',
                            value: _trackStock,
                            onChanged: (bool value) => setState(() => _trackStock = value),
                          ),
                          _SwitchRow(
                            label: 'Se vende por peso (granel)',
                            value: _sellByWeight,
                            onChanged: (bool value) =>
                                setState(() => _sellByWeight = value),
                          ),
                          _SwitchRow(
                            label: 'Favorito (primero en la venta)',
                            value: _isFavorite,
                            onChanged: (bool value) => setState(() => _isFavorite = value),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (_isEditing) ...<Widget>[
                  const SizedBox(height: AppSpacing.xs),
                  const HintText(
                    'Para cambiar las existencias use "Movimiento" en la tabla: así '
                    'queda registrado en el kardex quién, cuándo y por qué.',
                  ),
                ],
                const SizedBox(height: AppSpacing.md),
                TextFormField(
                  controller: _description,
                  maxLines: 2,
                  decoration: const InputDecoration(labelText: 'Descripción (opcional)'),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancelar'),
        ),
        PrimaryButton(
          label: _isEditing ? 'Guardar cambios' : 'Crear producto',
          icon: Icons.save_outlined,
          onPressed: _save,
        ),
      ],
    );
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? true)) return;

    final Money price = Money.tryParse(_price.text) ?? Money.zero;
    final Money cost = Money.tryParse(_cost.text) ?? Money.zero;
    final Quantity stock = Quantity.tryParse(_stock.text) ?? Quantity.zero;
    final Quantity minStock = Quantity.tryParse(_minStock.text) ?? Quantity.zero;
    final User? user = ref.read(currentUserProvider);

    try {
      if (_isEditing) {
        final Product product = widget.product!;
        await ref.read(appDatabaseProvider).productsDao.updateProduct(
              product: product,
              name: _name.text,
              sku: _sku.text,
              barcode: _barcode.text,
              description: _description.text.trim().isEmpty ? null : _description.text.trim(),
              categoryId: _categoryId,
              clearCategory: _categoryId == null,
              unit: _unit,
              price: price,
              cost: cost,
              taxRateBps: _taxRateBps,
              minStock: minStock,
              trackStock: _trackStock,
              sellByWeight: _sellByWeight,
              isFavorite: _isFavorite,
              auditNote: 'Editado por ${user?.fullName ?? 'sistema'}',
            );

        // El stock no se toca aquí a propósito: solo el kardex lo mueve.
      } else {
        final Product created = await ref.read(appDatabaseProvider).productsDao
            .createProduct(
          name: _name.text,
          price: price,
          sku: _sku.text,
          barcode: _barcode.text,
          description: _description.text.trim().isEmpty ? null : _description.text.trim(),
          categoryId: _categoryId,
          unit: _unit,
          cost: cost,
          taxRateBps: _taxRateBps,
          stock: _trackStock ? stock : Quantity.zero,
          minStock: minStock,
          trackStock: _trackStock,
          sellByWeight: _sellByWeight,
          isFavorite: _isFavorite,
        );

        if (created.trackStock && stock.isPositive) {
          await ref.read(appDatabaseProvider).inventoryDao.registerInitialStock(
                product: created,
                quantity: stock,
                unitCost: cost,
              );
        }
      }

      if (mounted) Navigator.of(context).pop(true);
    } on AppFailure catch (failure) {
      if (mounted) AppSnack.error(context, failure.message);
    } on Object catch (error) {
      if (mounted) AppSnack.error(context, 'No se pudo guardar el producto: $error');
    }
  }
}

/// Campo monetario.
class _MoneyField extends StatelessWidget {
  const _MoneyField({
    required this.controller,
    required this.label,
    required this.symbol,
    this.onChanged,
    this.validator,
  });

  final TextEditingController controller;
  final String label;
  final String symbol;
  final VoidCallback? onChanged;
  final String? Function(String?)? validator;

  @override
  Widget build(BuildContext context) => TextFormField(
        controller: controller,
        textAlign: TextAlign.right,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: <TextInputFormatter>[
          FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
        ],
        decoration: InputDecoration(labelText: label, prefixText: '$symbol '),
        validator: validator,
        onChanged: onChanged == null ? null : (_) => onChanged!(),
      );
}

/// Campo de cantidad (acepta 0.25 kg, 3 unidades…).
class _QuantityField extends StatelessWidget {
  const _QuantityField({
    required this.controller,
    required this.label,
    this.enabled = true,
  });

  final TextEditingController controller;
  final String label;
  final bool enabled;

  @override
  Widget build(BuildContext context) => TextFormField(
        controller: controller,
        enabled: enabled,
        textAlign: TextAlign.right,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: <TextInputFormatter>[
          FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
        ],
        decoration: InputDecoration(
          labelText: label,
          helperText: enabled ? null : 'Se ajusta con movimientos',
        ),
      );
}

/// Margen calculado en vivo.
class _MarginPreview extends StatelessWidget {
  const _MarginPreview({
    required this.price,
    required this.cost,
    required this.currency,
  });

  final Money price;
  final Money cost;
  final CurrencyFormat currency;

  @override
  Widget build(BuildContext context) {
    final Money margin = price - cost;
    final int bps = price.isPositive ? MoneyMath.mulDiv(margin.cents, 10000, price.cents) : 0;
    final Color color = margin.isNegative
        ? AppColors.red
        : (bps < 1500 ? AppColors.orange : AppColors.success);

    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: AppRadius.mdAll,
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            margin.isNegative ? Icons.trending_down : Icons.trending_up,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Margen',
                  style: AppTypography.label.copyWith(fontSize: 9, color: color),
                ),
                Text(
                  '${currency.money(margin)} · ${AppFormat.percent(bps)}',
                  style: AppTypography.bodyStrong.copyWith(fontSize: 12.5, color: color),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Interruptor compacto con etiqueta.
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 32,
        child: Row(
          children: <Widget>[
            Transform.scale(
              scale: 0.8,
              child: Switch(value: value, onChanged: onChanged),
            ),
            Expanded(
              child: Text(
                label,
                style: AppTypography.body.copyWith(fontSize: 12),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
}
