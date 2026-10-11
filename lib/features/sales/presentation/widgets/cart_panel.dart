import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/providers.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/ui/app_widgets.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../core/utils/money.dart';
import '../../application/cart_controller.dart';
import '../../domain/cart.dart';

/// Carrito de la venta.
///
/// Es una tabla densa, de alto contraste y con cifras tabulares: el cajero lee
/// importes alineados verticalmente de un vistazo, sin contar dígitos. Se opera
/// con teclado (doble clic o F7 abren el editor de línea) y con ratón.
class CartPanel extends ConsumerWidget {
  const CartPanel({super.key, required this.currency});

  final CurrencyFormat currency;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Cart cart = ref.watch(cartProvider);
    final CartComputation computation = ref.watch(cartComputationProvider);

    return AppCard(
      padding: EdgeInsets.zero,
      title: 'Venta',
      subtitle: cart.isEmpty
          ? 'Sin artículos'
          : '${cart.itemCount} línea(s) · ${AppFormat.quantityMilli(cart.totalQuantityMilli)} unidad(es)',
      actions: <Widget>[
        if (cart.isNotEmpty)
          IconButton(
            tooltip: 'Vaciar carrito (Esc)',
            icon: const Icon(Icons.delete_sweep_outlined, size: 17),
            onPressed: () => ref.read(cartProvider.notifier).clear(),
          ),
      ],
      child: Column(
        children: <Widget>[
          if (cart.hasCustomer) _CustomerStrip(cart: cart),
          const _CartHeaderRow(),
          Expanded(
            child: cart.isEmpty
                ? const EmptyState(
                    title: 'La venta está vacía',
                    message: 'Escanee un código de barras o haga clic en un producto '
                        'para comenzar.',
                    icon: Icons.shopping_cart_outlined,
                  )
                : ListView.builder(
                    padding: EdgeInsets.zero,
                    itemCount: cart.lines.length,
                    itemBuilder: (BuildContext context, int index) {
                      final CartLine line = cart.lines[index];
                      return _CartLineRow(
                        index: index + 1,
                        line: line,
                        totals: computation.forLine(line.lineId),
                        currency: currency,
                      );
                    },
                  ),
          ),
          const Divider(height: 1, color: AppColors.divider),
          _CartFooter(cart: cart, computation: computation, currency: currency),
        ],
      ),
    );
  }
}

/// Franja con el cliente seleccionado y su descuento.
class _CustomerStrip extends ConsumerWidget {
  const _CustomerStrip({required this.cart});

  final Cart cart;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.xs,
        ),
        color: AppColors.cyanSurface,
        child: Row(
          children: <Widget>[
            const Icon(Icons.person_outline, size: 15, color: AppColors.cyanDark),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                cart.customerName ?? 'Cliente',
                style: AppTypography.caption.copyWith(
                  fontWeight: FontWeight.w600,
                  color: AppColors.deepBlue,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (cart.customerDiscountBps > 0)
              StatusChip(
                label: 'Descuento cliente ${AppFormat.percent(cart.customerDiscountBps)}',
                color: AppColors.orange,
              ),
            IconButton(
              tooltip: 'Quitar cliente',
              iconSize: 15,
              visualDensity: VisualDensity.compact,
              onPressed: () => ref.read(cartProvider.notifier).setCustomer(),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      );
}

/// Encabezado de la tabla del carrito.
class _CartHeaderRow extends StatelessWidget {
  const _CartHeaderRow();

  @override
  Widget build(BuildContext context) {
    const TextStyle style = AppTypography.label;
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      decoration: const BoxDecoration(
        color: AppColors.grey50,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: <Widget>[
          const SizedBox(width: 22, child: Text('#', style: style)),
          const Expanded(flex: 5, child: Text('Producto', style: style)),
          const SizedBox(
            width: 96,
            child: Text('Cant.', style: style, textAlign: TextAlign.right),
          ),
          const SizedBox(
            width: 84,
            child: Text('P. unit.', style: style, textAlign: TextAlign.right),
          ),
          const SizedBox(
            width: 74,
            child: Text('Desc.', style: style, textAlign: TextAlign.right),
          ),
          const SizedBox(
            width: 96,
            child: Text('Importe', style: style, textAlign: TextAlign.right),
          ),
          const SizedBox(width: 34),
        ],
      ),
    );
  }
}

/// Una línea del carrito.
class _CartLineRow extends ConsumerStatefulWidget {
  const _CartLineRow({
    required this.index,
    required this.line,
    required this.totals,
    required this.currency,
  });

  final int index;
  final CartLine line;
  final LineTotals? totals;
  final CurrencyFormat currency;

  @override
  ConsumerState<_CartLineRow> createState() => _CartLineRowState();
}

class _CartLineRowState extends ConsumerState<_CartLineRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final CartLine line = widget.line;
    final Money amount = widget.totals?.total ?? line.netBeforeOrderDiscount;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onDoubleTap: () => _openEditor(),
        child: Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          decoration: BoxDecoration(
            color: _hovered ? AppColors.grey50 : Colors.transparent,
            border: const Border(bottom: BorderSide(color: AppColors.grey100)),
          ),
          child: Row(
            children: <Widget>[
              SizedBox(
                width: 22,
                child: Text(
                  '${widget.index}',
                  style: AppTypography.caption.copyWith(color: AppColors.textHint),
                ),
              ),
              Expanded(
                flex: 5,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      line.name,
                      style: AppTypography.body.copyWith(fontSize: 12.5),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (line.note != null || line.discountBps > 0 || line.isWeighted)
                      Text(
                        <String>[
                          if (line.isWeighted) 'a granel',
                          if (line.discountBps > 0)
                            'desc. ${AppFormat.percent(line.discountBps)}',
                          if (line.note != null) line.note!,
                        ].join(' · '),
                        style: AppTypography.caption.copyWith(
                          fontSize: 9.5,
                          color: AppColors.textHint,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              SizedBox(
                width: 96,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: <Widget>[
                    _QuantityButton(
                      icon: Icons.remove,
                      visible: _hovered || line.quantity.milli > 1000,
                      onTap: () => ref
                          .read(cartProvider.notifier)
                          .decrement(line.lineId),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text(
                        AppFormat.quantityMilli(line.quantity.milli),
                        style: AppTypography.tableStrong.copyWith(fontSize: 12.5),
                      ),
                    ),
                    _QuantityButton(
                      icon: Icons.add,
                      visible: _hovered,
                      onTap: () =>
                          ref.read(cartProvider.notifier).increment(line.lineId),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 84,
                child: Text(
                  widget.currency.formatCents(line.unitPrice.cents, withSymbol: false),
                  textAlign: TextAlign.right,
                  style: AppTypography.table.copyWith(fontSize: 12),
                ),
              ),
              SizedBox(
                width: 74,
                child: Text(
                  line.discountTotal.isZero
                      ? '—'
                      : '-${widget.currency.formatCents(line.discountTotal.cents, withSymbol: false)}',
                  textAlign: TextAlign.right,
                  style: AppTypography.table.copyWith(
                    fontSize: 12,
                    color: line.discountTotal.isZero
                        ? AppColors.textHint
                        : AppColors.orange,
                  ),
                ),
              ),
              SizedBox(
                width: 96,
                child: MoneyText(
                  amount,
                  currency: widget.currency,
                  size: 13,
                ),
              ),
              SizedBox(
                width: 34,
                child: IconButton(
                  tooltip: 'Quitar línea (F8)',
                  iconSize: 15,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  onPressed: () =>
                      ref.read(cartProvider.notifier).removeLine(line.lineId),
                  icon: Icon(
                    Icons.close,
                    color: _hovered ? AppColors.red : AppColors.grey300,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openEditor() async {
    final CartLine line = widget.line;
    final CartLineEdit? edit = await showDialog<CartLineEdit>(
      context: context,
      builder: (BuildContext context) => _CartLineEditorDialog(
        line: line,
        currency: widget.currency,
      ),
    );
    if (edit == null || !mounted) return;

    final CartController controller = ref.read(cartProvider.notifier);
    if (edit.quantity != null) controller.setQuantity(line.lineId, edit.quantity!);
    if (edit.price != null) controller.overrideLinePrice(line.lineId, edit.price!);
    controller.applyLineDiscount(
      line.lineId,
      bps: edit.discountBps ?? 0,
      amount: edit.discountAmount ?? Money.zero,
    );
    controller.setLineNote(line.lineId, edit.note);
  }
}

/// Botón circular pequeño para sumar/restar cantidades.
class _QuantityButton extends StatelessWidget {
  const _QuantityButton({
    required this.icon,
    required this.onTap,
    this.visible = true,
  });

  final IconData icon;
  final VoidCallback onTap;
  final bool visible;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 20,
        height: 20,
        child: visible
            ? IconButton(
                padding: EdgeInsets.zero,
                iconSize: 13,
                visualDensity: VisualDensity.compact,
                onPressed: onTap,
                icon: Icon(icon, color: AppColors.cyanDark),
              )
            : null,
      );
}

/// Pie del carrito: descuento general, nota y cliente.
class _CartFooter extends ConsumerWidget {
  const _CartFooter({
    required this.cart,
    required this.computation,
    required this.currency,
  });

  final Cart cart;
  final CartComputation computation;
  final CurrencyFormat currency;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: TextEditingController(text: cart.note ?? '')
                  ..selection = TextSelection.collapsed(
                    offset: (cart.note ?? '').length,
                  ),
                onChanged: (String value) =>
                    ref.read(cartProvider.notifier).setNote(value),
                style: AppTypography.caption.copyWith(fontSize: 12),
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'Nota de la venta (opcional)',
                  prefixIcon: Icon(Icons.sticky_note_2_outlined, size: 15),
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            if (!cart.orderDiscountAmount.isZero || cart.orderDiscountBps > 0)
              StatusChip(
                label: cart.orderDiscountBps > 0
                    ? 'Desc. general ${AppFormat.percent(cart.orderDiscountBps)}'
                    : 'Desc. general ${currency.money(cart.orderDiscountAmount)}',
                color: AppColors.orange,
                icon: Icons.percent,
              ),
          ],
        ),
      );
}

/// Resultado del editor de línea.
@immutable
class CartLineEdit {
  const CartLineEdit({
    this.quantity,
    this.price,
    this.discountBps,
    this.discountAmount,
    this.note,
  });

  final Quantity? quantity;
  final Money? price;
  final int? discountBps;
  final Money? discountAmount;
  final String? note;
}

/// Editor de línea: cantidad, precio, descuento y nota.
///
/// Todos los campos son opcionales: solo se aplica lo que el cajero modifica.
class _CartLineEditorDialog extends StatefulWidget {
  const _CartLineEditorDialog({required this.line, required this.currency});

  final CartLine line;
  final CurrencyFormat currency;

  @override
  State<_CartLineEditorDialog> createState() => _CartLineEditorDialogState();
}

class _CartLineEditorDialogState extends State<_CartLineEditorDialog> {
  late final TextEditingController _quantity =
      TextEditingController(text: MoneyMath.quantityString(widget.line.quantity.milli));
  late final TextEditingController _price =
      TextEditingController(text: (widget.line.unitPrice.cents / 100).toStringAsFixed(2));
  late final TextEditingController _discount =
      TextEditingController(text: (widget.line.discountBps / 100).toStringAsFixed(2));
  late final TextEditingController _note =
      TextEditingController(text: widget.line.note ?? '');

  @override
  void dispose() {
    _quantity.dispose();
    _price.dispose();
    _discount.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        icon: const Icon(Icons.edit_note, color: AppColors.cyan, size: 26),
        title: Text(widget.line.name, overflow: TextOverflow.ellipsis),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: _Field(
                      label: widget.line.isWeighted ? 'Cantidad (kg/lb)' : 'Cantidad',
                      controller: _quantity,
                      suffix: widget.line.isWeighted ? null : 'u',
                      autofocus: true,
                      onSubmitted: (_) => _submit(),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: _Field(
                      label: 'Precio unitario',
                      controller: _price,
                      suffix: widget.currency.symbol,
                      onSubmitted: (_) => _submit(),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: <Widget>[
                  Expanded(
                    child: _Field(
                      label: 'Descuento (%)',
                      controller: _discount,
                      suffix: '%',
                      onSubmitted: (_) => _submit(),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: _Field(
                      label: 'Nota de la línea',
                      controller: _note,
                      onSubmitted: (_) => _submit(),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              const HintText(
                'El precio y el descuento quedan registrados en la venta. '
                'Los cambios de precio se auditan con el nombre del cajero.',
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: _submit,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.orange,
              foregroundColor: AppColors.white,
            ),
            child: const Text('Aplicar'),
          ),
        ],
      );

  void _submit() {
    final Quantity? quantity = Quantity.tryParse(_quantity.text);
    final Money? price = Money.tryParse(_price.text);
    final double? percent = double.tryParse(_discount.text.replaceAll(',', '.'));
    final String note = _note.text.trim();

    Navigator.of(context).pop(
      CartLineEdit(
        quantity: quantity != null && quantity.isPositive ? quantity : null,
        price: price != null && !price.isNegative ? price : null,
        discountBps: percent == null ? null : (percent * 100).round(),
        note: note.isEmpty ? null : note,
      ),
    );
  }
}

/// Campo de texto compacto con etiqueta, usado en los diálogos de venta.
class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.controller,
    this.suffix,
    this.autofocus = false,
    this.onSubmitted,
  });

  final String label;
  final TextEditingController controller;
  final String? suffix;
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) => TextField(
        controller: controller,
        autofocus: autofocus,
        textAlign: TextAlign.right,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: <TextInputFormatter>[
          FilteringTextInputFormatter.allow(RegExp(r'[0-9.,\-]')),
        ],
        decoration: InputDecoration(labelText: label, suffixText: suffix),
        onSubmitted: onSubmitted,
      );
}
