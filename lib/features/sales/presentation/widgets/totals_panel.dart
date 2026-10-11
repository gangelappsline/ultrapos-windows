import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/domain/sale_totals.dart';
import '../../../../core/providers.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/ui/app_widgets.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../core/utils/money.dart';
import '../../application/cart_controller.dart';
import '../../domain/cart.dart';

/// Panel de totales y acciones de cobro.
///
/// Jerarquía visual deliberada: el **total** es el elemento más grande de la
/// pantalla y el botón **Cobrar (F12)** el único naranja del módulo. Todo lo
/// demás (descuento, cliente, espera) es secundario y no compite por la mirada
/// del cajero cuando el cliente está esperando con el dinero en la mano.
class TotalsPanel extends ConsumerWidget {
  const TotalsPanel({
    super.key,
    required this.currency,
    required this.onCheckout,
    required this.onHold,
    required this.onRecall,
    required this.onDiscount,
    required this.onCustomer,
    this.company,
  });

  final CurrencyFormat currency;
  final VoidCallback? onCheckout;
  final VoidCallback? onHold;
  final VoidCallback onRecall;
  final VoidCallback? onDiscount;
  final VoidCallback onCustomer;
  final CompanyProfile? company;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Cart cart = ref.watch(cartProvider);
    final CartComputation computation = ref.watch(cartComputationProvider);
    final SaleTotals totals = computation.totals;
    final int heldCount = ref.watch(heldCountProvider).value ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // --- Cliente ---
        AppCard(
          padding: const EdgeInsets.all(AppSpacing.sm),
          child: InkWell(
            onTap: onCustomer,
            child: Row(
              children: <Widget>[
                const Icon(Icons.person_add_alt, size: 17, color: AppColors.cyanDark),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        cart.hasCustomer ? 'Cliente' : 'Consumidor Final',
                        style: AppTypography.label.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                      Text(
                        cart.customerName ?? 'Clic o F3 para asignar cliente',
                        style: AppTypography.body.copyWith(
                          fontSize: 12.5,
                          fontWeight: cart.hasCustomer ? FontWeight.w600 : FontWeight.w400,
                          color: cart.hasCustomer
                              ? AppColors.textPrimary
                              : AppColors.textHint,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, size: 18, color: AppColors.grey400),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),

        // --- Totales ---
        Expanded(
          child: AppCard(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _TotalRow(
                  label: 'Artículos',
                  value: '${cart.itemCount}',
                ),
                _TotalRow(
                  label: 'Subtotal',
                  value: currency.money(computation.totals.subtotal),
                ),
                if (!computation.totals.discountTotal.isZero)
                  _TotalRow(
                    label: 'Descuentos',
                    value: '-${currency.money(computation.totals.discountTotal)}',
                    color: AppColors.orange,
                  ),
                const Divider(height: AppSpacing.md, color: AppColors.divider),
                for (final MapEntry<int, Money> entry
                    in (computation.totals.taxByRate.entries.toList()
                      ..sort((MapEntry<int, Money> a, MapEntry<int, Money> b) =>
                          a.key.compareTo(b.key))))
                  if (!entry.value.isZero)
                    _TotalRow(
                      label: 'Impuesto ${AppFormat.percent(entry.key)}',
                      value: currency.money(entry.value),
                      muted: true,
                    ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(
                    gradient: AppColors.totalGradient,
                    borderRadius: AppRadius.lgAll,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Text(
                        'TOTAL A PAGAR',
                        style: AppTypography.label.copyWith(
                          color: AppColors.white70,
                          letterSpacing: 1.2,
                        ),
                      ),
                      const SizedBox(height: 2),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          currency.money(computation.totals.total),
                          style: AppTypography.display.copyWith(
                            fontSize: 36,
                            color: AppColors.white,
                          ),
                        ),
                      ),
                      if (company != null)
                        Text(
                          '${company!.taxLabel} '
                          '${AppFormat.percent(company!.defaultTaxRateBps)}'
                          '${company!.taxIncludedInPrice ? ' incluido' : ' + impuesto'}',
                          style: AppTypography.caption.copyWith(
                            color: AppColors.white70,
                            fontSize: 10,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        totals.roundingAdjustment.isZero
            ? const SizedBox.shrink()
            : Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                child: Text(
                  'Ajuste por redondeo: ${currency.money(totals.roundingAdjustment)}',
                  style: AppTypography.caption.copyWith(color: AppColors.textSecondary),
                ),
              ),

        // --- Acciones ---
        PrimaryButton(
          label: 'COBRAR',
          icon: Icons.payments_outlined,
          large: true,
          expand: true,
          shortcut: 'F12',
          onPressed: onCheckout,
          tooltip: 'Cobrar la venta (F12)',
        ),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: <Widget>[
            Expanded(
              child: SecondaryButton(
                label: 'Descuento',
                icon: Icons.percent,
                shortcut: 'F6',
                expand: true,
                onPressed: onDiscount,
              ),
            ),
            const SizedBox(width: AppSpacing.xs),
            Expanded(
              child: SecondaryButton(
                label: 'En espera',
                icon: Icons.pause_circle_outline,
                shortcut: 'F4',
                expand: true,
                onPressed: onHold,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Row(
          children: <Widget>[
            Expanded(
              child: SecondaryButton(
                label: heldCount > 0 ? 'Recuperar ($heldCount)' : 'Recuperar',
                icon: Icons.play_circle_outline,
                expand: true,
                onPressed: onRecall,
              ),
            ),
            const SizedBox(width: AppSpacing.xs),
            Expanded(
              child: SecondaryButton(
                label: 'Cliente',
                icon: Icons.person_search,
                shortcut: 'F3',
                expand: true,
                onPressed: onCustomer,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Fila de total (etiqueta a la izquierda, importe tabular a la derecha).
class _TotalRow extends StatelessWidget {
  const _TotalRow({
    required this.label,
    required this.value,
    this.color,
    this.muted = false,
  });

  final String label;
  final String value;
  final Color? color;
  final bool muted;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                label,
                style: muted
                    ? AppTypography.caption.copyWith(color: AppColors.textSecondary)
                    : AppTypography.body.copyWith(fontSize: 12.5),
              ),
            ),
            Text(
              value,
              style: (muted ? AppTypography.table : AppTypography.tableStrong).copyWith(
                fontSize: muted ? 12 : 13,
                color: color ?? AppColors.textPrimary,
              ),
            ),
          ],
        ),
      );
}
