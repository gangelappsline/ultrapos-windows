import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/domain/enums.dart';
import '../../../../core/domain/sale_totals.dart';
import '../../../../core/errors/app_failure.dart';
import '../../../../core/providers.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/ui/app_widgets.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../core/utils/money.dart';
import '../../../auth/application/session_controller.dart';
import '../../application/checkout_service.dart';
import '../../domain/cart.dart';

/// Diálogo de cobro: el momento más crítico de la jornada.
///
/// Diseño orientado a la velocidad y a la ausencia de errores:
///   * El total y el vuelto son enormes: se leen de reojo.
///   * Botones de billetes frecuentes: cobrar en efectivo son dos clics.
///   * Pago mixto con lista visible y validación en vivo.
///   * `Enter` cobra, `Esc` vuelve a la venta sin perder nada.
///   * Si la impresora falla, **la venta ya está guardada**: se informa y se
///     ofrece reimprimir.
class PaymentDialog extends ConsumerStatefulWidget {
  const PaymentDialog({
    super.key,
    required this.cart,
    required this.computation,
    required this.currency,
    required this.allowCredit,
  });

  final Cart cart;
  final CartComputation computation;
  final CurrencyFormat currency;
  final bool allowCredit;

  static Future<CheckoutResult?> show(
    BuildContext context, {
    required Cart cart,
    required CartComputation computation,
    required CurrencyFormat currency,
    required bool allowCredit,
  }) =>
      showDialog<CheckoutResult>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext context) => PaymentDialog(
          cart: cart,
          computation: computation,
          currency: currency,
          allowCredit: allowCredit,
        ),
      );

  @override
  ConsumerState<PaymentDialog> createState() => _PaymentDialogState();
}

class _PaymentDialogState extends ConsumerState<PaymentDialog> {
  final TextEditingController _amount = TextEditingController();
  final FocusNode _amountFocus = FocusNode(debugLabel: 'payment-amount');

  PaymentMethod _method = PaymentMethod.cash;
  final List<PaymentRequest> _payments = <PaymentRequest>[];
  bool _processing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _amount.text = '';
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _prefillExact();
    });
  }

  @override
  void dispose() {
    _amount.dispose();
    _amountFocus.dispose();
    super.dispose();
  }

  Money get _total => widget.computation.totals.total;

  Money get _paid => _payments.fold(
        Money.zero,
        (Money sum, PaymentRequest p) => sum + p.amount,
      );

  /// Diferencia: positiva = falta por cubrir; negativa = sobra (vuelto).
  Money get _remaining => _total - _paid;

  int get _cashCents => _payments
      .where((PaymentRequest p) => p.method == PaymentMethod.cash)
      .fold(0, (int sum, PaymentRequest p) => sum + p.amount.cents);

  Money get _change {
    final int raw = _cashCents - _total.cents;
    return Money(raw > 0 ? raw : 0);
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.enter): () => _prefillExact(),
      },
      child: AlertDialog(
        contentPadding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.lg,
          AppSpacing.lg,
          AppSpacing.sm,
        ),
        insetPadding: const EdgeInsets.all(AppSpacing.lg),
        title: Row(
          children: <Widget>[
            const Icon(Icons.payments_outlined, color: AppColors.orange, size: 22),
            const SizedBox(width: AppSpacing.sm),
            const Text('Cobrar venta'),
            const Spacer(),
            Text(
              '${widget.cart.itemCount} artículo(s)',
              style: AppTypography.caption.copyWith(color: AppColors.textSecondary),
            ),
          ],
        ),
        content: SizedBox(
          width: 680,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _AmountBanner(
                total: _total,
                paid: _paid,
                remaining: _remaining,
                change: _change,
                currency: widget.currency,
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(flex: 3, child: _methodColumn()),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(flex: 2, child: _paymentsColumn()),
                ],
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
            onPressed: _processing ? null : () => Navigator.of(context).pop(),
            child: const Text('Volver (Esc)'),
          ),
          SizedBox(
            width: 210,
            child: PrimaryButton(
              label: _processing ? 'Cobrando…' : 'COBRAR',
              icon: Icons.check_circle_outline,
              large: true,
              expand: true,
              shortcut: 'F12',
              onPressed: _processing || _remaining.isPositive ? null : _confirm,
            ),
          ),
        ],
      ),
    );
  }

  Widget _methodColumn() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const SectionLabel('Forma de pago'),
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: <Widget>[
              for (final PaymentMethod method in <PaymentMethod>[
                PaymentMethod.cash,
                PaymentMethod.card,
                PaymentMethod.transfer,
                if (widget.allowCredit) PaymentMethod.credit,
              ])
                _MethodChip(
                  method: method,
                  selected: _method == method,
                  onTap: () => setState(() {
                    _method = method;
                    _error = null;
                  }),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _amount,
                  focusNode: _amountFocus,
                  autofocus: true,
                  textAlign: TextAlign.right,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: <TextInputFormatter>[
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.,\-]')),
                  ],
                  style: AppTypography.tableStrong.copyWith(fontSize: 15),
                  decoration: InputDecoration(
                    labelText: 'Importe recibido',
                    prefixText: '${widget.currency.symbol} ',
                    hintText: (_remaining.isPositive ? _remaining : _total)
                        .units
                        .toStringAsFixed(2),
                  ),
                  onSubmitted: (_) => _addCurrent(),
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              SizedBox(
                height: AppSpacing.controlHeight,
                child: SecondaryButton(
                  label: 'Agregar',
                  icon: Icons.add,
                  onPressed: _addCurrent,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          // Billetes frecuentes: cobrar en efectivo sin escribir nada.
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: <Widget>[
              _QuickAmountButton(
                label: 'Exacto',
                onTap: _prefillExact,
              ),
              for (final Money bill in _quickBills())
                _QuickAmountButton(
                  label: widget.currency.formatCents(bill.cents, withSymbol: false),
                  onTap: () => _setAmount(bill),
                ),
            ],
          ),
        ],
      );

  Widget _paymentsColumn() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SectionLabel(
            'Pagos',
            trailing: _payments.isEmpty
                ? null
                : Text(
                    '${_payments.length}',
                    style: AppTypography.caption,
                  ),
          ),
          Container(
            height: 176,
            decoration: BoxDecoration(
              color: AppColors.grey50,
              borderRadius: AppRadius.mdAll,
              border: Border.all(color: AppColors.border),
            ),
            child: _payments.isEmpty
                ? Center(
                    child: Text(
                      'Aún no hay pagos',
                      style: AppTypography.caption.copyWith(color: AppColors.textHint),
                    ),
                  )
                : ListView.builder(
                    itemCount: _payments.length,
                    itemBuilder: (BuildContext context, int index) {
                      final PaymentRequest payment = _payments[index];
                      return ListTile(
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        leading: Icon(_iconFor(payment.method), size: 16),
                        title: Text(
                          payment.method.label,
                          style: AppTypography.caption.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: payment.reference == null
                            ? null
                            : Text(payment.reference!, style: AppTypography.caption),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Text(
                              widget.currency.money(payment.amount),
                              style: AppTypography.table.copyWith(fontSize: 12),
                            ),
                            IconButton(
                              iconSize: 14,
                              visualDensity: VisualDensity.compact,
                              onPressed: () => setState(() {
                                _payments.removeAt(index);
                                _error = null;
                              }),
                              icon: const Icon(Icons.close, color: AppColors.grey400),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          const SizedBox(height: AppSpacing.xs),
          _BreakdownRow(
            label: 'Recibido',
            value: widget.currency.money(_paid),
            currency: widget.currency,
          ),
          _BreakdownRow(
            label: _remaining.isNegative ? 'Vuelto' : 'Falta',
            value: widget.currency.money(
              _remaining.isNegative ? Money(-_remaining.cents) : _remaining,
            ),
            color: _remaining.isPositive ? AppColors.red : AppColors.success,
            currency: widget.currency,
          ),
        ],
      );

  /// Billetes/monedas útiles según el total de la venta.
  List<Money> _quickBills() {
    final List<int> candidates = <int>[1000, 2000, 5000, 10000, 20000, 50000];
    final List<Money> bills = <Money>[];
    for (final int cents in candidates) {
      if (cents >= _total.cents) bills.add(Money(cents));
      if (bills.length >= 3) break;
    }
    return bills;
  }

  void _setAmount(Money amount) {
    _amount.text = amount.units.toStringAsFixed(2);
    _amount.selection = TextSelection.collapsed(offset: _amount.text.length);
  }

  void _prefillExact() {
    final Money remaining = _remaining;
    if (remaining.isPositive) _setAmount(remaining);
  }

  void _addCurrent() {
    final Money? amount = Money.tryParse(_amount.text);
    if (amount == null || !amount.isPositive) {
      setState(() => _error = 'Escriba un importe válido (por ejemplo 150.00).');
      return;
    }

    // Un pago en efectivo nunca debe exceder lo que falta + el vuelto que el
    // cajero ya decidió entregar; el sobrante se interpreta siempre como vuelto.
    if (_method != PaymentMethod.cash && amount > _remaining) {
      setState(() => _error =
          'Un pago con ${_method.label.toLowerCase()} no puede exceder el total.');
      return;
    }

    setState(() {
      _payments.add(PaymentRequest(method: _method, amount: amount));
      _amount.clear();
      _error = null;
      // Si ya se cubrió el total en efectivo, el método vuelve a efectivo para
      // el siguiente cobro (evita quedarse "pegado" en tarjeta por descuido).
      if (!_remaining.isPositive) _method = PaymentMethod.cash;
    });
    _amountFocus.requestFocus();
  }

  Future<void> _confirm() async {
    final CartComputation computation = widget.computation;
    final PaymentValidation validation = PaymentValidator.validate(
      totals: computation.totals,
      payments: _payments,
      hasCustomer: widget.cart.hasCustomer,
      allowCredit: widget.allowCredit,
    );
    if (!validation.isValid) {
      setState(() => _error = validation.message);
      return;
    }

    final User? user = ref.read(currentUserProvider);
    final CompanyProfile? company = ref.read(companyProfileProvider).value;
    if (user == null || company == null) {
      setState(() => _error = 'La sesión o el perfil de la empresa no están listos.');
      return;
    }

    setState(() {
      _processing = true;
      _error = null;
    });

    final OperationSettings rules =
        ref.read(operationSettingsProvider).value ?? OperationSettings.defaults;
    final CheckoutService service = CheckoutService(
      database: ref.read(appDatabaseProvider),
      hardware: ref.read(hardwareManagerProvider),
    );

    try {
      final CheckoutResult result = await service.checkout(
        cart: widget.cart,
        computation: computation,
        payments: List<PaymentRequest>.unmodifiable(_payments),
        user: user,
        company: company,
        cashSession: ref.read(cashSessionProvider).value,
        allowCredit: widget.allowCredit,
        requireOpenSession: rules.requireOpenSession,
        printTicket: true,
        openDrawer: true,
      );
      if (!mounted) return;
      ref.read(syncServiceProvider).notifyLocalChanges();
      Navigator.of(context).pop(result);
    } on AppFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _processing = false;
        _error = failure.message;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _processing = false;
        _error = 'No se pudo completar el cobro: $error';
      });
    }
  }
}

/// Icono de cada forma de pago (detalle de presentación, no de dominio).
IconData _iconFor(PaymentMethod method) => switch (method) {
      PaymentMethod.cash => Icons.payments_outlined,
      PaymentMethod.card => Icons.credit_card,
      PaymentMethod.transfer => Icons.account_balance_outlined,
      PaymentMethod.credit => Icons.handshake_outlined,
      PaymentMethod.other => Icons.more_horiz,
    };

/// Franja superior con total, recibido y vuelto.
class _AmountBanner extends StatelessWidget {
  const _AmountBanner({
    required this.total,
    required this.paid,
    required this.remaining,
    required this.change,
    required this.currency,
  });

  final Money total;
  final Money paid;
  final Money remaining;
  final Money change;
  final CurrencyFormat currency;

  @override
  Widget build(BuildContext context) {
    final bool isCredit = remaining.isPositive;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        gradient: AppColors.totalGradient,
        borderRadius: AppRadius.lgAll,
      ),
      child: Row(
        children: <Widget>[
          _BannerValue(
            label: 'TOTAL',
            value: currency.money(total),
            emphasis: true,
          ),
          _BannerDivider(),
          _BannerValue(label: 'RECIBIDO', value: currency.money(paid)),
          _BannerDivider(),
          _BannerValue(
            label: isCredit ? 'FALTA' : 'VUELTO',
            value: currency.money(isCredit ? remaining : change),
            color: isCredit ? AppColors.orangeLight : AppColors.successSurface,
            emphasis: true,
          ),
        ],
      ),
    );
  }
}

class _BannerValue extends StatelessWidget {
  const _BannerValue({
    required this.label,
    required this.value,
    this.color = AppColors.white,
    this.emphasis = false,
  });

  final String label;
  final String value;
  final Color color;
  final bool emphasis;

  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              label,
              style: AppTypography.label.copyWith(
                color: AppColors.white54,
                fontSize: 9.5,
                letterSpacing: 1.1,
              ),
            ),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                style: AppTypography.display.copyWith(
                  fontSize: emphasis ? 26 : 19,
                  color: color,
                ),
              ),
            ),
          ],
        ),
      );
}

class _BannerDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
        width: 1,
        height: 34,
        margin: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
        color: AppColors.white24,
      );
}

class _MethodChip extends StatelessWidget {
  const _MethodChip({
    required this.method,
    required this.selected,
    required this.onTap,
  });

  final PaymentMethod method;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: selected ? AppColors.deepBlue : AppColors.grey100,
        borderRadius: AppRadius.mdAll,
        child: InkWell(
          onTap: onTap,
          borderRadius: AppRadius.mdAll,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  _iconFor(method),
                  size: 15,
                  color: selected ? AppColors.white : AppColors.textSecondary,
                ),
                const SizedBox(width: 6),
                Text(
                  method.label,
                  style: AppTypography.body.copyWith(
                    fontSize: 12.5,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: selected ? AppColors.white : AppColors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}

class _QuickAmountButton extends StatelessWidget {
  const _QuickAmountButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
          minimumSize: const Size(0, 28),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          side: const BorderSide(color: AppColors.border),
          foregroundColor: AppColors.deepBlue,
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.smAll),
        ),
        child: Text(label, style: AppTypography.caption.copyWith(fontSize: 11.5)),
      );
}

class _BreakdownRow extends StatelessWidget {
  const _BreakdownRow({
    required this.label,
    required this.value,
    required this.currency,
    this.color,
  });

  final String label;
  final String value;
  final CurrencyFormat currency;
  final Color? color;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                label,
                style: AppTypography.caption.copyWith(color: AppColors.textSecondary),
              ),
            ),
            Text(
              value,
              style: AppTypography.tableStrong.copyWith(
                fontSize: 12,
                color: color ?? AppColors.textPrimary,
              ),
            ),
          ],
        ),
      );
}
