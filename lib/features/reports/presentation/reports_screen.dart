import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/domain/enums.dart';
import '../../../core/domain/report_models.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/providers.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/ui/app_widgets.dart';
import '../../../core/ui/charts.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/utils/money.dart';
import '../application/report_exporter.dart';

/// Rango temporal del reporte.
enum ReportRange {
  today('Hoy', 0),
  week('Esta semana', 6),
  month('Este mes', 29),
  quarter('90 días', 89);

  const ReportRange(this.label, this.daysBack);

  final String label;
  final int daysBack;

  DateTime get from {
    final DateTime now = DateTime.now();
    final DateTime day = DateTime(now.year, now.month, now.day);
    return day.subtract(Duration(days: daysBack));
  }

  DateTime get to => DateTime.now();

  /// Rango inmediatamente anterior de la misma duración (para comparar).
  DateTime get previousFrom => from.subtract(Duration(days: daysBack + 1));
}

/// Rango seleccionado en la pantalla de reportes.
///
/// Riverpod 3 retiró `StateProvider` al paquete `legacy`; un `Notifier` es la
/// forma vigente y además deja el cambio de rango en un método con nombre.
class ReportRangeController extends Notifier<ReportRange> {
  @override
  ReportRange build() => ReportRange.today;

  void select(ReportRange range) => state = range;
}

final reportRangeProvider =
    NotifierProvider<ReportRangeController, ReportRange>(ReportRangeController.new);

/// Resumen del período activo.
final salesSummaryProvider = FutureProvider<SalesSummary>((Ref ref) {
  final ReportRange range = ref.watch(reportRangeProvider);
  return ref.watch(appDatabaseProvider).reportsDao.summaryFor(range.from, range.to);
});

/// Resumen del período anterior equivalente (para variaciones).
final previousSummaryProvider = FutureProvider<SalesSummary>((Ref ref) {
  final ReportRange range = ref.watch(reportRangeProvider);
  return ref
      .watch(appDatabaseProvider)
      .reportsDao
      .summaryFor(range.previousFrom, range.from.subtract(const Duration(seconds: 1)));
});

/// Serie temporal de ventas por día.
final salesSeriesProvider = FutureProvider<List<TimeSeriesPoint>>((Ref ref) {
  final ReportRange range = ref.watch(reportRangeProvider);
  return ref.watch(appDatabaseProvider).reportsDao.salesByDay(from: range.from, to: range.to);
});

final topProductsProvider = FutureProvider<List<TopProductRow>>((Ref ref) {
  final ReportRange range = ref.watch(reportRangeProvider);
  return ref
      .watch(appDatabaseProvider)
      .reportsDao
      .topProducts(from: range.from, to: range.to, limit: 10);
});

final paymentBreakdownProvider = FutureProvider<List<PaymentBreakdownRow>>((Ref ref) {
  final ReportRange range = ref.watch(reportRangeProvider);
  return ref.watch(appDatabaseProvider).reportsDao.paymentBreakdown(range.from, range.to);
});

final categorySalesProvider = FutureProvider<List<CategorySalesRow>>((Ref ref) {
  final ReportRange range = ref.watch(reportRangeProvider);
  return ref.watch(appDatabaseProvider).reportsDao.salesByCategory(range.from, range.to);
});

final cashierPerformanceProvider = FutureProvider<List<CashierPerformanceRow>>((Ref ref) {
  final ReportRange range = ref.watch(reportRangeProvider);
  return ref.watch(appDatabaseProvider).reportsDao.salesByCashier(range.from, range.to);
});

/// Módulo de reportes.
///
/// Se abre en "Hoy" porque es la pregunta que se hace el dueño al llegar por la
/// tarde ("¿cómo va el día?"), y ofrece los rangos siguientes con un solo clic.
/// Todos los datos salen de SQL agregado (no se cargan ventas completas en
/// memoria): con 200.000 tickets el panel sigue abriendo al instante.
class ReportsScreen extends ConsumerWidget {
  const ReportsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ReportRange range = ref.watch(reportRangeProvider);
    final CurrencyFormat currency = ref.watch(currencyFormatProvider);
    final AsyncValue<SalesSummary> summary = ref.watch(salesSummaryProvider);
    final SalesSummary? previous = ref.watch(previousSummaryProvider).value;

    return Padding(
      padding: AppSpacing.screenPadding,
      child: Column(
        children: <Widget>[
          ModuleHeader(
            title: 'Reportes',
            subtitle: 'Ventas, productos y comportamiento del negocio',
            actions: <Widget>[
              for (final ReportRange option in ReportRange.values)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: ChoiceChip(
                    label: Text(option.label),
                    selected: range == option,
                    onSelected: (_) =>
                        ref.read(reportRangeProvider.notifier).select(option),
                    selectedColor: AppColors.deepBlue,
                    labelStyle: AppTypography.caption.copyWith(
                      color: range == option ? AppColors.white : AppColors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                    showCheckmark: false,
                  ),
                ),
              const SizedBox(width: AppSpacing.sm),
              SecondaryButton(
                label: 'Exportar',
                icon: Icons.ios_share,
                onPressed: () => _export(context, ref, range),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Expanded(
            child: summary.when(
              data: (SalesSummary data) => SingleChildScrollView(
                child: Column(
                  children: <Widget>[
                    _KpiRow(
                      summary: data,
                      previous: previous,
                      currency: currency,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Expanded(
                          flex: 3,
                          child: AppCard(
                            title: 'Ventas por día',
                            subtitle: '${AppFormat.shortDate(range.from)} — '
                                '${AppFormat.shortDate(range.to)}',
                            child: ref.watch(salesSeriesProvider).when(
                                  data: (List<TimeSeriesPoint> points) => SalesBarChart(
                                    bars: points
                                        .map(
                                          (TimeSeriesPoint p) => ChartBar(
                                            label: p.label,
                                            value: p.total,
                                          ),
                                        )
                                        .toList(growable: false),
                                    currency: currency,
                                  ),
                                  error: (Object e, _) => ErrorState(message: '$e'),
                                  loading: () => const LoadingState(),
                                ),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          flex: 2,
                          child: AppCard(
                            title: 'Formas de pago',
                            child: ref.watch(paymentBreakdownProvider).when(
                                  data: (List<PaymentBreakdownRow> rows) =>
                                      ShareDonutChart(
                                    currency: currency,
                                    centerLabel: 'Cobrado',
                                    slices: rows
                                        .map(
                                          (PaymentBreakdownRow row) => ChartBar(
                                            label: row.method.label,
                                            value: row.amount,
                                          ),
                                        )
                                        .toList(growable: false),
                                  ),
                                  error: (Object e, _) => ErrorState(message: '$e'),
                                  loading: () => const LoadingState(),
                                ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Expanded(
                          child: AppCard(
                            title: 'Productos más vendidos',
                            child: ref.watch(topProductsProvider).when(
                                  data: (List<TopProductRow> rows) => rows.isEmpty
                                      ? const EmptyState(
                                          title: 'Sin ventas en el período',
                                          icon: Icons.insights_outlined,
                                        )
                                      : Column(
                                          children: <Widget>[
                                            for (final TopProductRow row in rows)
                                              RankedBar(
                                                label: row.productName,
                                                value: row.revenue,
                                                max: rows.first.revenue,
                                                subtitle:
                                                    '${AppFormat.quantityMilli(row.quantityMilli)} u · '
                                                    '${row.lines} ticket(s)',
                                              ),
                                          ],
                                        ),
                                  error: (Object e, _) => ErrorState(message: '$e'),
                                  loading: () => const LoadingState(),
                                ),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: AppCard(
                            title: 'Ventas por categoría',
                            child: ref.watch(categorySalesProvider).when(
                                  data: (List<CategorySalesRow> rows) => rows.isEmpty
                                      ? const EmptyState(
                                          title: 'Sin datos',
                                          icon: Icons.category_outlined,
                                        )
                                      : ShareDonutChart(
                                          currency: currency,
                                          centerLabel: 'Total',
                                          slices: rows
                                              .take(6)
                                              .map(
                                                (CategorySalesRow row) => ChartBar(
                                                  label: row.categoryName,
                                                  value: row.revenue,
                                                ),
                                              )
                                              .toList(growable: false),
                                        ),
                                  error: (Object e, _) => ErrorState(message: '$e'),
                                  loading: () => const LoadingState(),
                                ),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: AppCard(
                            title: 'Desempeño por cajero',
                            child: ref.watch(cashierPerformanceProvider).when(
                                  data: (List<CashierPerformanceRow> rows) => rows.isEmpty
                                      ? const EmptyState(
                                          title: 'Sin datos',
                                          icon: Icons.badge_outlined,
                                        )
                                      : Column(
                                          children: <Widget>[
                                            for (final CashierPerformanceRow row in rows)
                                              RankedBar(
                                                label: row.userName,
                                                value: row.total,
                                                max: rows.first.total,
                                                color: AppColors.deepBlue,
                                                subtitle:
                                                    '${row.transactionCount} ticket(s) · '
                                                    'promedio ${currency.money(row.averageTicket)}',
                                              ),
                                          ],
                                        ),
                                  error: (Object e, _) => ErrorState(message: '$e'),
                                  loading: () => const LoadingState(),
                                ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              error: (Object error, _) => ErrorState(message: '$error'),
              loading: () => const LoadingState(message: 'Calculando reportes…'),
            ),
          ),
        ],
      ),
    );
  }

  /// Exportación a PDF y CSV/Excel.
  Future<void> _export(BuildContext context, WidgetRef ref, ReportRange range) async {
    final _ExportFormat? format = await showDialog<_ExportFormat>(
      context: context,
      builder: (BuildContext context) => const _ExportDialog(),
    );
    if (format == null || !context.mounted) return;

    try {
      final CompanyProfile? company = ref.read(companyProfileProvider).value;
      if (company == null) {
        throw const NotFoundFailure(
          message: 'No se pudo cargar el perfil del negocio.',
        );
      }

      final String? path = await ReportExporter.exportSalesReport(
        database: ref.read(appDatabaseProvider),
        company: company,
        from: range.from,
        to: range.to,
        currency: ref.read(currencyFormatProvider),
        asPdf: format == _ExportFormat.pdf,
      );

      if (path == null) return; // El usuario canceló el diálogo.
      if (context.mounted) {
        AppSnack.success(
          context,
          'Reporte guardado en ${path.split(Platform.pathSeparator).last}',
        );
      }
    } on AppFailure catch (failure) {
      if (context.mounted) AppSnack.error(context, failure.message);
    } on Object catch (error) {
      if (context.mounted) AppSnack.error(context, 'No se pudo exportar: $error');
    }
  }
}

/// Fila de indicadores principales.
class _KpiRow extends StatelessWidget {
  const _KpiRow({
    required this.summary,
    required this.previous,
    required this.currency,
  });

  final SalesSummary summary;
  final SalesSummary? previous;
  final CurrencyFormat currency;

  /// Utilidad bruta del período: venta cobrada menos costo de lo vendido.
  Money get _profit => summary.grossTotal - summary.costTotal;

  Money? get _previousProfit =>
      previous == null ? null : previous!.grossTotal - previous!.costTotal;

  @override
  Widget build(BuildContext context) => Row(
        children: <Widget>[
          Expanded(
            child: KpiCard(
              label: 'Venta total',
              value: currency.money(summary.grossTotal),
              icon: Icons.point_of_sale_outlined,
              color: AppColors.deepBlue,
              hint: '${summary.transactionCount} ticket(s)',
              trendBps: _trend(summary.grossTotal, previous?.grossTotal),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: KpiCard(
              label: 'Ticket promedio',
              value: currency.money(summary.averageTicket),
              icon: Icons.receipt_long_outlined,
              hint: 'Por transacción',
              trendBps: _trend(summary.averageTicket, previous?.averageTicket),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: KpiCard(
              label: 'Impuestos generados',
              value: currency.money(summary.taxTotal),
              icon: Icons.account_balance_outlined,
              color: AppColors.cyan,
              hint: 'Base: ${currency.money(summary.netTotal)}',
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: KpiCard(
              label: 'Utilidad estimada',
              value: currency.money(_profit),
              icon: Icons.trending_up,
              color: AppColors.success,
              hint: 'Venta menos costo',
              trendBps: _trend(_profit, _previousProfit),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: KpiCard(
              label: 'Anulaciones',
              value: '${summary.voidCount}',
              icon: Icons.cancel_outlined,
              color: summary.voidCount > 0 ? AppColors.red : AppColors.grey400,
              hint: currency.money(summary.voidTotal),
            ),
          ),
        ],
      );

  /// Variación porcentual en basis points.
  static int? _trend(Money current, Money? previous) {
    if (previous == null || previous.isZero) return null;
    final Money delta = current - previous;
    return MoneyMath.mulDiv(delta.cents, 10000, previous.cents);
  }
}

/// Formatos de exportación.
enum _ExportFormat { pdf, csv }

/// Selección del formato de exportación.
class _ExportDialog extends StatelessWidget {
  const _ExportDialog();

  @override
  Widget build(BuildContext context) => AlertDialog(
        icon: const Icon(Icons.ios_share, color: AppColors.cyan),
        title: const Text('Exportar reporte'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.picture_as_pdf_outlined, color: AppColors.red),
                title: const Text('PDF para imprimir o enviar'),
                subtitle: Text(
                  'Resumen ejecutivo, series y ranking de productos',
                  style: AppTypography.caption,
                ),
                onTap: () => Navigator.of(context).pop(_ExportFormat.pdf),
              ),
              ListTile(
                leading: const Icon(Icons.table_chart_outlined, color: AppColors.success),
                title: const Text('CSV (se abre en Excel)'),
                subtitle: Text(
                  'Ventas línea a línea para análisis contable',
                  style: AppTypography.caption,
                ),
                onTap: () => Navigator.of(context).pop(_ExportFormat.csv),
              ),
              const SizedBox(height: AppSpacing.sm),
              const HintText(
                'Los archivos se guardan donde usted elija. El CSV usa punto y coma '
                'como separador y UTF-8, para que Excel en español lo abra bien.',
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancelar'),
          ),
        ],
      );
}
