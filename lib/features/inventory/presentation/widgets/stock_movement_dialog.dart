import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/database/daos/inventory_dao.dart';
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

/// Modos que ofrece el formulario (el conteo físico no es un tipo del kardex:
/// el sistema decide si fue positivo o negativo comparando con el stock real).
enum _MovementMode {
  purchase('Entrada por compra', Icons.add_business_outlined, StockMovementType.purchase),
  adjustmentIn('Ajuste positivo', Icons.trending_up, StockMovementType.adjustmentIn),
  adjustmentOut('Ajuste negativo', Icons.trending_down, StockMovementType.adjustmentOut),
  loss('Merma / pérdida', Icons.delete_outline, StockMovementType.loss),
  returnIn('Devolución de cliente', Icons.assignment_return_outlined, StockMovementType.returnIn),
  transferOut('Traslado saliente', Icons.call_made, StockMovementType.transferOut),
  transferIn('Traslado entrante', Icons.call_received, StockMovementType.transferIn),
  physicalCount('Conteo físico', Icons.fact_check_outlined, StockMovementType.adjustmentIn);

  const _MovementMode(this.label, this.icon, this.type);

  final String label;
  final IconData icon;
  final StockMovementType type;
}

/// Movimiento de inventario: entrada, merma, conteo físico o ajuste.
///
/// Todo cambio de existencias pasa por aquí (nunca editando el stock a mano)
/// para que el kardex conserve el rastro completo: producto, tipo, cantidad,
/// costo, motivo, usuario y fecha. Es lo que permite responder semanas después
/// "¿por qué faltan 3 unidades?".
class StockMovementDialog extends ConsumerStatefulWidget {
  const StockMovementDialog({super.key, required this.product});

  final Product product;

  static Future<bool?> show(BuildContext context, {required Product product}) =>
      showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext context) => StockMovementDialog(product: product),
      );

  @override
  ConsumerState<StockMovementDialog> createState() => _StockMovementDialogState();
}

class _StockMovementDialogState extends ConsumerState<StockMovementDialog> {
  final TextEditingController _quantity = TextEditingController();
  final TextEditingController _unitCost = TextEditingController();
  final TextEditingController _reason = TextEditingController();

  _MovementMode _mode = _MovementMode.purchase;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _unitCost.text = widget.product.cost.units.toStringAsFixed(2);
  }

  @override
  void dispose() {
    _quantity.dispose();
    _unitCost.dispose();
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final CurrencyFormat currency = ref.watch(currencyFormatProvider);
    final Product product = widget.product;
    final Quantity? entered = Quantity.tryParse(_quantity.text);
    final Quantity projected = entered == null
        ? product.stock
        : (_mode.type.increases ? product.stock + entered : product.stock - entered);

    return AlertDialog(
      contentPadding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      title: Row(
        children: <Widget>[
          const Icon(Icons.swap_vert, color: AppColors.cyan, size: 22),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              'Movimiento de inventario',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            AppCard(
              color: AppColors.grey50,
              border: false,
              padding: const EdgeInsets.all(AppSpacing.sm),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(product.name, style: AppTypography.bodyStrong),
                        Text(
                          'Stock actual: ${AppFormat.quantity(product.stock)} '
                          '${product.unit.abbreviation}',
                          style: AppTypography.caption,
                        ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      Text('QUEDARÁ', style: AppTypography.label.copyWith(fontSize: 9)),
                      Text(
                        AppFormat.quantityMilli(projected.milli),
                        style: AppTypography.subtitle.copyWith(
                          fontSize: 18,
                          color: projected.isNegative ? AppColors.red : AppColors.deepBlue,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            const SectionLabel('Tipo de movimiento'),
            Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xs,
              children: <Widget>[
                for (final _MovementMode mode in _MovementMode.values)
                  ChoiceChip(
                    label: Text(mode.label),
                    selected: _mode == mode,
                    avatar: Icon(
                      mode.icon,
                      size: 15,
                      color: _mode == mode ? AppColors.white : AppColors.deepBlue,
                    ),
                    labelStyle: AppTypography.caption.copyWith(
                      color: _mode == mode ? AppColors.white : AppColors.textPrimary,
                      fontWeight: _mode == mode ? FontWeight.w600 : FontWeight.w400,
                    ),
                    selectedColor: _mode == mode ? AppColors.deepBlue : null,
                    onSelected: (_) => setState(() {
                      _mode = mode;
                      _error = null;
                    }),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _quantity,
                    autofocus: true,
                    textAlign: TextAlign.right,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: <TextInputFormatter>[
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                    ],
                    decoration: InputDecoration(
                      labelText: 'Cantidad',
                      suffixText: product.unit.abbreviation,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                if (_mode == _MovementMode.purchase)
                  Expanded(
                    child: TextField(
                      controller: _unitCost,
                      textAlign: TextAlign.right,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: <TextInputFormatter>[
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                      ],
                      decoration: InputDecoration(
                        labelText: 'Costo unitario',
                        prefixText: '${currency.symbol} ',
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _reason,
              decoration: InputDecoration(
                labelText: _mode == _MovementMode.purchase
                    ? 'Proveedor o factura'
                    : 'Motivo (obligatorio)',
                hintText: _mode == _MovementMode.physicalCount
                    ? 'Conteo semanal de bodega'
                    : 'Producto dañado, vencido, faltante…',
              ),
              onChanged: (_) => setState(() => _error = null),
            ),
            if (_error != null) ...<Widget>[
              const SizedBox(height: AppSpacing.sm),
              InlineBanner(
                message: _error!,
                icon: Icons.error_outline,
                color: AppColors.red,
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancelar'),
        ),
        PrimaryButton(
          label: _saving ? 'Registrando…' : 'Registrar movimiento',
          icon: Icons.check,
          onPressed: _saving ? null : _save,
        ),
      ],
    );
  }

  Future<void> _save() async {
    final Product product = widget.product;
    final Quantity? quantity = Quantity.tryParse(_quantity.text);
    if (quantity == null || quantity.isZero) {
      setState(() => _error = 'Escriba una cantidad mayor que cero.');
      return;
    }
    final String reason = _reason.text.trim();
    if (_mode != _MovementMode.purchase && reason.isEmpty) {
      setState(() => _error = 'Indique el motivo del movimiento (queda en el kardex).');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    final User? user = ref.read(currentUserProvider);
    final InventoryDao dao = ref.read(appDatabaseProvider).inventoryDao;

    try {
      if (_mode == _MovementMode.physicalCount) {
        // El conteo fija el stock real, no suma ni resta a ciegas.
        await dao.applyPhysicalCount(
          product: product,
          counted: quantity,
          reason: reason.isEmpty ? 'Conteo físico' : reason,
          userName: user?.fullName,
        );
      } else {
        await dao.adjustStock(
          product: product,
          type: _mode.type,
          quantity: quantity,
          unitCost: _mode == _MovementMode.purchase
              ? Money.tryParse(_unitCost.text)
              : null,
          reason: reason.isEmpty ? 'Entrada de mercancía' : reason,
          userName: user?.fullName,
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } on AppFailure catch (failure) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = failure.message;
        });
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'No se pudo registrar el movimiento: $error';
        });
      }
    }
  }
}
