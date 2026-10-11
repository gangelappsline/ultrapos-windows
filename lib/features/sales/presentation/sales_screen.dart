import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/database/app_database.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/providers.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/ui/app_widgets.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/utils/money.dart';
import '../../auth/application/session_controller.dart';
import '../application/cart_controller.dart';
import '../application/checkout_service.dart';
import 'widgets/cart_panel.dart';
import 'widgets/customer_picker_dialog.dart';
import 'widgets/payment_dialog.dart';
import 'widgets/product_search_panel.dart';
import 'widgets/totals_panel.dart';

/// Pantalla de venta — el corazón de UltraPOS.
///
/// Diseño de tres columnas, pensado para trabajar **a 1366×768** con teclado y
/// lector de códigos, sin tocar el ratón:
///
///   ┌────────────────────┬───────────────────────────┬──────────────────┐
///   │ Búsqueda y         │ Carrito (líneas)          │ Totales, cliente │
///   │ productos          │                           │ y COBRAR (F12)   │
///   └────────────────────┴───────────────────────────┴──────────────────┘
///
/// Atajos implementados aquí (los globales del shell se suman a estos):
///   F2 buscar · F6 descuento general · F12 cobrar · Esc cancelar venta
class SalesScreen extends ConsumerStatefulWidget {
  const SalesScreen({super.key});

  @override
  ConsumerState<SalesScreen> createState() => _SalesScreenState();
}

class _SalesScreenState extends ConsumerState<SalesScreen> {
  final FocusNode _shortcutFocus = FocusNode(debugLabel: 'sales-shortcuts');

  @override
  void dispose() {
    _shortcutFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Cart cart = ref.watch(cartProvider);
    final CompanyProfile? company = ref.watch(companyProfileProvider).value;
    final CurrencyFormat currency = ref.watch(currencyFormatProvider);

    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.f12): const _CheckoutIntent(),
        const SingleActivator(LogicalKeyboardKey.f6): const _OrderDiscountIntent(),
        const SingleActivator(LogicalKeyboardKey.f8): const _RemoveLastLineIntent(),
        const SingleActivator(LogicalKeyboardKey.escape): const _ClearCartIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _CheckoutIntent: CallbackAction<_CheckoutIntent>(
            onInvoke: (_) {
              _checkout();
              return null;
            },
          ),
          _OrderDiscountIntent: CallbackAction<_OrderDiscountIntent>(
            onInvoke: (_) {
              _askOrderDiscount();
              return null;
            },
          ),
          _RemoveLastLineIntent: CallbackAction<_RemoveLastLineIntent>(
            onInvoke: (_) {
              if (cart.lines.isNotEmpty) {
                ref
                    .read(cartProvider.notifier)
                    .removeLine(cart.lines.last.lineId);
              }
              return null;
            },
          ),
          _ClearCartIntent: CallbackAction<_ClearCartIntent>(
            onInvoke: (_) {
              if (cart.isNotEmpty) _confirmClearCart();
              return null;
            },
          ),
        },
        child: Focus(
          focusNode: _shortcutFocus,
          autofocus: true,
          child: Padding(
            padding: AppSpacing.screenPadding,
            child: Column(
              children: <Widget>[
                _SalesToolbar(
                  onClear: cart.isEmpty ? null : _confirmClearCart,
                  onDiscount: cart.isEmpty ? null : _askOrderDiscount,
                  onRecall: _recallHeldOrder,
                ),
                const SizedBox(height: AppSpacing.md),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      // Columna izquierda: búsqueda + resultados
                      const Expanded(flex: 4, child: ProductSearchPanel()),
                      const SizedBox(width: AppSpacing.md),
                      // Columna central: carrito
                      Expanded(
                        flex: 5,
                        child: CartPanel(currency: currency),
                      ),
                      const SizedBox(width: AppSpacing.md),
                      // Columna derecha: totales y cobro
                      SizedBox(
                        width: AppSpacing.totalsPanelWidth,
                        child: TotalsPanel(
                          currency: currency,
                          onCheckout: cart.isEmpty ? null : _checkout,
                          onHold: cart.isEmpty ? null : _holdOrder,
                          onRecall: _recallHeldOrder,
                          onDiscount: cart.isEmpty ? null : _askOrderDiscount,
                          onCustomer: _pickCustomer,
                          company: company,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Acciones
  // ---------------------------------------------------------------------------

  Future<void> _checkout() async {
    final Cart cart = ref.read(cartProvider);
    if (cart.isEmpty) {
      AppSnack.warning(context, 'Agregue al menos un producto para cobrar.');
      return;
    }

    final CartComputation computation = ref.read(cartComputationProvider);
    final OperationSettings rules =
        ref.read(operationSettingsProvider).value ?? OperationSettings.defaults;

    final CheckoutResult? result = await PaymentDialog.show(
      context,
      cart: cart,
      computation: computation,
      currency: ref.read(currencyFormatProvider),
      allowCredit: rules.allowCreditSales,
    );
    if (result == null || !mounted) return;

    ref.read(cartProvider.notifier).clear();

    final CurrencyFormat currency = ref.read(currencyFormatProvider);
    if (result.printed) {
      AppSnack.success(
        context,
        'Venta ${result.folio} cobrada · ${currency.money(result.totals.total)}',
      );
    } else {
      // La venta ya está registrada: la impresora es un accesorio, no un
      // requisito. Se avisa y se sigue trabajando.
      AppSnack.warning(
        context,
        'Venta ${result.folio} cobrada, pero no se imprimió. '
        '${result.printError ?? 'Revise la impresora e imprima de nuevo con Ctrl+P.'}',
      );
    }

    if (result.hasChange) {
      await _showChangeDialog(result);
    }
  }

  Future<void> _showChangeDialog(CheckoutResult result) async {
    if (!mounted) return;
    final CurrencyFormat currency = ref.read(currencyFormatProvider);
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        icon: const Icon(Icons.payments_outlined, color: AppColors.orange, size: 30),
        title: const Text('Entregue el vuelto'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text('Total cobrado: ${currency.money(result.totals.total)}'),
            const SizedBox(height: AppSpacing.sm),
            Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                gradient: AppColors.totalGradient,
                borderRadius: AppRadius.lgAll,
              ),
              child: Text(
                currency.money(result.change),
                style: AppTypography.display.copyWith(
                  fontSize: 34,
                  color: AppColors.white,
                ),
              ),
            ),
          ],
        ),
        actions: <Widget>[
          PrimaryButton(
            label: 'Vuelto entregado',
            icon: Icons.check,
            onPressed: () => Navigator.of(context).pop(),
            shortcut: 'Enter',
          ),
        ],
      ),
    );
  }

  Future<void> _confirmClearCart() async {
    final bool confirmed = await ConfirmDialog.show(
      context,
      title: 'Cancelar la venta',
      message: 'Se quitarán todos los productos del carrito. '
          'Si necesita conservarla, use "En espera" (F4).',
      confirmLabel: 'Cancelar venta',
      destructive: true,
    );
    if (confirmed) ref.read(cartProvider.notifier).clear();
  }

  Future<void> _askOrderDiscount() async {
    final Cart cart = ref.read(cartProvider);
    if (cart.isEmpty) return;
    final int? bps = await showDialog<int>(
      context: context,
      builder: (BuildContext context) => const _DiscountDialog(),
    );
    if (bps == null) return;
    ref.read(cartProvider.notifier).applyOrderDiscount(bps: bps);
    AppSnack.info(context, 'Descuento general: ${AppFormat.percent(bps)}');
  }

  Future<void> _pickCustomer() async {
    final Customer? customer = await CustomerPickerDialog.show(context);
    if (customer == null) return;
    ref.read(cartProvider.notifier).setCustomer(customer);
  }

  /// Guarda la venta como pedido en espera (F4) liberando la caja.
  Future<void> _holdOrder() async {
    final Cart cart = ref.read(cartProvider);
    if (cart.isEmpty) return;
    final String? label = await _askOrderLabel();
    if (label == null || !mounted) return;

    final User? user = ref.read(currentUserProvider);
    if (user == null) {
      AppSnack.error(context, 'La sesión expiró. Vuelva a identificarse.');
      return;
    }

    try {
      final AppDatabase database = ref.read(appDatabaseProvider);
      await database.salesDao.holdOrder(
        existing: null,
        request: CheckoutService.buildSaleRequest(
          cart: cart,
          computation: ref.read(cartComputationProvider),
          user: user,
          folioPrefix: (await database.settingsDao.device())?.folioPrefix ?? 'A',
          cashSession: ref.read(cashSessionProvider).value,
          status: SaleStatus.held,
          orderLabel: label,
        ),
        totals: ref.read(cartComputationProvider).totals,
      );
      ref.read(cartProvider.notifier).clear();
      ref.invalidate(heldOrdersProvider);
      ref.invalidate(heldCountProvider);
      if (mounted) AppSnack.success(context, 'Pedido "$label" guardado en espera.');
    } on AppFailure catch (failure) {
      if (mounted) AppSnack.error(context, failure.message);
    } on Object catch (error) {
      if (mounted) AppSnack.error(context, 'No se pudo poner en espera: $error');
    }
  }

  Future<String?> _askOrderLabel() => showDialog<String>(
        context: context,
        builder: (BuildContext context) => const _OrderLabelDialog(),
      );

  /// Recupera un pedido en espera al carrito actual.
  Future<void> _recallHeldOrder() async {
    final AppDatabase database = ref.read(appDatabaseProvider);
    final List<Sale> held = await database.salesDao.heldOrders();
    if (!mounted) return;

    if (held.isEmpty) {
      AppSnack.info(context, 'No hay pedidos en espera.');
      return;
    }

    final Sale? selected = await showDialog<Sale>(
      context: context,
      builder: (BuildContext context) => _HeldOrdersDialog(orders: held),
    );
    if (selected == null || !mounted) return;

    final SaleDetails? details = await database.salesDao.detailsFor(selected.uuid);
    if (details == null || !mounted) return;

    await ref.read(cartProvider.notifier).loadHeldOrder(details);
    AppSnack.success(context, 'Pedido "${selected.orderLabel ?? selected.folio}" recuperado.');
  }
}

/// Barra de herramientas de la pantalla de venta.
class _SalesToolbar extends ConsumerWidget {
  const _SalesToolbar({
    required this.onClear,
    required this.onDiscount,
    required this.onRecall,
  });

  final VoidCallback? onClear;
  final VoidCallback? onDiscount;
  final VoidCallback onRecall;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final int heldCount = ref.watch(heldCountProvider).value ?? 0;
    final SessionState session = ref.watch(sessionProvider);

    return Row(
      children: <Widget>[
        Text('Nueva venta', style: AppTypography.headline.copyWith(fontSize: 19)),
        const SizedBox(width: AppSpacing.sm),
        StatusChip(
          label: session.user?.employeeCode == null
              ? session.displayName
              : '${session.displayName} · #${session.user!.employeeCode}',
          color: AppColors.cyanDark,
          icon: Icons.badge_outlined,
        ),
        const Spacer(),
        if (heldCount > 0)
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.sm),
            child: StatusChip(
              label: '$heldCount en espera',
              color: AppColors.orange,
              icon: Icons.pause_circle_outline,
            ),
          ),
        SecondaryButton(
          label: 'En espera',
          icon: Icons.pause_circle_outline,
          shortcut: 'F4',
          onPressed: onRecall,
          tooltip: 'Guardar/recuperar un pedido en espera',
        ),
        const SizedBox(width: AppSpacing.sm),
        SecondaryButton(
          label: 'Descuento',
          icon: Icons.percent,
          shortcut: 'F6',
          onPressed: onDiscount,
        ),
        const SizedBox(width: AppSpacing.sm),
        SecondaryButton(
          label: 'Cancelar',
          icon: Icons.close,
          shortcut: 'Esc',
          onPressed: onClear,
        ),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// Intents
// -----------------------------------------------------------------------------

class _CheckoutIntent extends Intent {
  const _CheckoutIntent();
}

class _OrderDiscountIntent extends Intent {
  const _OrderDiscountIntent();
}

class _RemoveLastLineIntent extends Intent {
  const _RemoveLastLineIntent();
}

class _ClearCartIntent extends Intent {
  const _ClearCartIntent();
}

/// Diálogo de descuento general (porcentaje o monto fijo).
class _DiscountDialog extends ConsumerStatefulWidget {
  const _DiscountDialog();

  @override
  ConsumerState<_DiscountDialog> createState() => _DiscountDialogState();
}

class _DiscountDialogState extends ConsumerState<_DiscountDialog> {
  final TextEditingController _controller = TextEditingController();
  bool _isPercentage = true;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final CartComputation computation = ref.watch(cartComputationProvider);
    final CurrencyFormat currency = ref.watch(currencyFormatProvider);
    final int? bps = _isPercentage ? int.tryParse(_controller.text) : null;

    return AlertDialog(
      icon: const Icon(Icons.percent, color: AppColors.orange),
      title: const Text('Descuento en la venta'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                ChoiceChip(
                  label: const Text('Porcentaje'),
                  selected: _isPercentage,
                  onSelected: (_) => setState(() => _isPercentage = true),
                ),
                const SizedBox(width: AppSpacing.sm),
                ChoiceChip(
                  label: const Text('Monto'),
                  selected: !_isPercentage,
                  onSelected: (_) => setState(() => _isPercentage = false),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _controller,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: _isPercentage ? 'Porcentaje (0-100)' : 'Monto a descontar',
                suffixText: _isPercentage ? '%' : currency.symbol,
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _apply(computation),
            ),
            const SizedBox(height: AppSpacing.sm),
            HintText(
              'Descuento máximo autorizado para ${ref.read(sessionProvider).displayName}: '
              '${AppFormat.percent(ref.read(sessionProvider).role.canVoidSales ? 10000 : 500)}',
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
          onPressed: bps != null && bps > 100 ? null : () => _apply(computation),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.orange,
            foregroundColor: AppColors.white,
          ),
          child: const Text('Aplicar'),
        ),
      ],
    );
  }

  void _apply(CartComputation computation) {
    final String raw = _controller.text.replaceAll(',', '.').trim();
    if (raw.isEmpty) {
      Navigator.of(context).pop(0);
      return;
    }
    if (_isPercentage) {
      final double percent = double.tryParse(raw) ?? -1;
      if (percent < 0 || percent > 100) return;
      Navigator.of(context).pop((percent * 100).round());
    } else {
      final Money amount = Money.tryParse(raw) ?? Money.zero;
      final Money base = computation.totals.subtotal;
      if (amount.isNegative || amount > base) return;
      Navigator.of(context).pop(
        base.isZero ? 0 : MoneyMath.mulDiv(amount.cents, 10000, base.cents),
      );
    }
  }
}

/// Diálogo para nombrar el pedido en espera.
class _OrderLabelDialog extends StatefulWidget {
  const _OrderLabelDialog();

  @override
  State<_OrderLabelDialog> createState() => _OrderLabelDialogState();
}

class _OrderLabelDialogState extends State<_OrderLabelDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        icon: const Icon(Icons.pause_circle_outline, color: AppColors.orange),
        title: const Text('Pedido en espera'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                controller: _controller,
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Referencia del pedido',
                  hintText: 'Mesa 4, Juan Pérez, Pedido azul…',
                ),
                onSubmitted: (String value) => _submit(value),
              ),
              const SizedBox(height: AppSpacing.sm),
              const HintText(
                'La venta se libera de la pantalla y podrá recuperarla con F4. '
                'Es ideal cuando el cliente va a buscar dinero o falta un producto.',
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
            onPressed: () => _submit(_controller.text),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.orange),
            child: const Text('Guardar'),
          ),
        ],
      );

  void _submit(String value) {
    final String label = value.trim();
    if (label.isEmpty) return;
    Navigator.of(context).pop(label);
  }
}

/// Lista de pedidos en espera para recuperar.
class _HeldOrdersDialog extends StatelessWidget {
  const _HeldOrdersDialog({required this.orders});

  final List<Sale> orders;

  @override
  Widget build(BuildContext context) {
    final CurrencyFormat currency = CurrencyFormat();
    return AlertDialog(
      icon: const Icon(Icons.pause_circle_outline, color: AppColors.orange),
      title: const Text('Pedidos en espera'),
      content: SizedBox(
        width: 560,
        height: 340,
        child: ListView.separated(
          itemCount: orders.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (BuildContext context, int index) {
            final Sale sale = orders[index];
            return ListTile(
              dense: true,
              leading: const Icon(Icons.receipt_long_outlined, size: 18),
              title: Text(
                sale.orderLabel ?? sale.folio,
                style: AppTypography.body.copyWith(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                '${AppFormat.dateTime(sale.createdAt)} · ${sale.userName} · '
                '${sale.itemCount} artículo(s)',
                style: AppTypography.caption,
              ),
              trailing: Text(
                currency.money(sale.total),
                style: AppTypography.table.copyWith(fontWeight: FontWeight.w700),
              ),
              onTap: () => Navigator.of(context).pop(sale),
            );
          },
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
}
