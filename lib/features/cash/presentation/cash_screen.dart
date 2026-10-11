import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/database/app_database.dart';
import '../../../core/database/daos/cash_dao.dart';
import '../../../core/domain/enums.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/providers.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/ui/app_widgets.dart';
import '../../../core/ui/charts.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/utils/money.dart';
import '../../auth/application/session_controller.dart';

/// Movimientos del turno abierto (stream reactivo).
final cashMovementsProvider = StreamProvider.family<List<CashMovement>, int>(
  (Ref ref, int sessionId) =>
      ref.watch(appDatabaseProvider).cashDao.watchMovements(sessionId),
);

/// Resumen calculado del turno (se recalcula al cambiar sus ventas o movimientos).
final cashSummaryProvider = FutureProvider.family<CashSessionSummary, int>(
  (Ref ref, int sessionId) async {
    // Se depende del flujo de movimientos para recalcular cuando algo cambia.
    ref.watch(cashMovementsProvider(sessionId));
    final CashSession? session =
        await ref.watch(appDatabaseProvider).cashDao.currentSession();
    if (session == null || session.id != sessionId) {
      throw const NotFoundFailure(message: 'El turno ya no está abierto.');
    }
    return ref.watch(appDatabaseProvider).cashDao.summarize(session);
  },
);

/// Módulo de caja: apertura, arqueo y cierre del turno.
///
/// Es el módulo que convierte la operación en dinero cuadrado. El diseño
/// responde a una pregunta concreta: *"si el cajero cierra ahora, ¿cuánto
/// efectivo debe haber en el cajón?"*. Todo lo demás (ventas por método,
/// entradas, salidas, anulaciones) existe para poder explicar la diferencia.
class CashScreen extends ConsumerWidget {
  const CashScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<CashSession?> session = ref.watch(cashSessionProvider);
    final CurrencyFormat currency = ref.watch(currencyFormatProvider);

    return Padding(
      padding: AppSpacing.screenPadding,
      child: Column(
        children: <Widget>[
          ModuleHeader(
            title: 'Caja',
            subtitle: 'Turnos, arqueo y movimientos de efectivo',
            actions: <Widget>[
              session.maybeWhen(
                data: (CashSession? open) => open == null
                    ? PrimaryButton(
                        label: 'Abrir turno',
                        icon: Icons.lock_open_outlined,
                        onPressed: () => _openSession(context, ref),
                      )
                    : PrimaryButton(
                        label: 'Cerrar y arquear',
                        icon: Icons.lock_outline,
                        color: AppColors.deepBlue,
                        onPressed: () => _closeSession(context, ref, open),
                      ),
                orElse: () => const SizedBox.shrink(),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Expanded(
            child: session.when(
              data: (CashSession? open) => open == null
                  ? const _ClosedState()
                  : _OpenSessionView(session: open, currency: currency),
              error: (Object error, _) => ErrorState(message: '$error'),
              loading: () => const LoadingState(message: 'Consultando el turno…'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openSession(BuildContext context, WidgetRef ref) async {
    final Money? opening = await showDialog<Money>(
      context: context,
      builder: (BuildContext context) => const _OpenSessionDialog(),
    );
    if (opening == null) return;

    final User? user = ref.read(currentUserProvider);
    if (user == null) {
      AppSnack.error(context, 'La sesión expiró.');
      return;
    }

    try {
      await ref.read(appDatabaseProvider).cashDao.openSession(
            openingAmount: opening,
            userId: user.id,
            userUuid: user.uuid,
            userName: user.fullName,
          );
      if (context.mounted) {
        AppSnack.success(context, 'Turno abierto con fondo de ${opening.units.toStringAsFixed(2)}.');
      }
    } on AppFailure catch (failure) {
      if (context.mounted) AppSnack.error(context, failure.message);
    }
  }

  Future<void> _closeSession(
    BuildContext context,
    WidgetRef ref,
    CashSession session,
  ) async {
    final CashSessionSummary summary =
        await ref.read(appDatabaseProvider).cashDao.summarize(session);
    if (!context.mounted) return;

    final _CloseResult? result = await showDialog<_CloseResult>(
      context: context,
      builder: (BuildContext context) => _CloseSessionDialog(
        session: session,
        summary: summary,
      ),
    );
    if (result == null) return;

    final User? user = ref.read(currentUserProvider);
    if (user == null) return;

    try {
      final CashSession closed = await ref.read(appDatabaseProvider).cashDao.closeSession(
            session: session,
            countedCash: result.countedCash,
            userId: user.id,
            userUuid: user.uuid,
            userName: user.fullName,
            note: result.note,
            denominations: result.denominations,
          );
      if (!context.mounted) return;

      // El cierre se imprime como respaldo firmado del arqueo.
      final CompanyProfile? company =
          ref.read(companyProfileProvider).value;
      if (company != null) {
        await ref.read(hardwareManagerProvider).printCashClose(
              session: closed,
              summary: summary,
              company: company,
            );
      }
      if (context.mounted) {
        AppSnack.success(
          context,
          'Turno cerrado. Diferencia: ${ref.read(currencyFormatProvider).money(summary.difference ?? Money.zero)}',
        );
      }
    } on AppFailure catch (failure) {
      if (context.mounted) AppSnack.error(context, failure.message);
    }
  }
}

/// Estado sin turno abierto: invita a abrir caja.
class _ClosedState extends StatelessWidget {
  const _ClosedState();

  @override
  Widget build(BuildContext context) => AppCard(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              const Icon(Icons.lock_outline, size: 42, color: AppColors.grey400),
              const SizedBox(height: AppSpacing.md),
              Text('La caja está cerrada', style: AppTypography.title),
              const SizedBox(height: AppSpacing.xs),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Text(
                  'Abra el turno indicando el fondo inicial (el efectivo con el que '
                  'comienza la jornada). A partir de ahí cada venta en efectivo y cada '
                  'movimiento quedarán asociados a este turno.',
                  textAlign: TextAlign.center,
                  style: AppTypography.caption.copyWith(color: AppColors.textSecondary),
                ),
              ),
            ],
          ),
        ),
      );
}

/// Vista del turno abierto.
class _OpenSessionView extends ConsumerWidget {
  const _OpenSessionView({required this.session, required this.currency});

  final CashSession session;
  final CurrencyFormat currency;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<CashSessionSummary> summary =
        ref.watch(cashSummaryProvider(session.id));
    final AsyncValue<List<CashMovement>> movements =
        ref.watch(cashMovementsProvider(session.id));

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          flex: 3,
          child: Column(
            children: <Widget>[
              AppCard(
                title: 'Turno abierto',
                subtitle: '${session.openedByName} · '
                    '${AppFormat.dateTime(session.openedAt)}',
                actions: <Widget>[
                  StatusChip(
                    label: 'Abierto ${_elapsed(session.openedAt)}',
                    color: AppColors.success,
                    icon: Icons.timer_outlined,
                  ),
                ],
                child: summary.when(
                  data: (CashSessionSummary data) => Column(
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          _Metric(
                            label: 'Efectivo esperado',
                            value: currency.money(data.expectedCash),
                            color: AppColors.deepBlue,
                            emphasis: true,
                          ),
                          _Metric(
                            label: 'Ventas',
                            value: '${data.salesCount}',
                            hint: currency.money(data.grossTotal),
                          ),
                          _Metric(
                            label: 'Ticket promedio',
                            value: currency.money(data.ticketAverage),
                          ),
                          _Metric(
                            label: 'Anuladas',
                            value: '${data.voidCount}',
                            hint: currency.money(data.voidTotal),
                            color: data.voidCount > 0 ? AppColors.red : null,
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.md),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Expanded(
                            flex: 3,
                            child: ShareDonutChart(
                              height: 200,
                              centerLabel: 'Cobrado',
                              currency: currency,
                              slices: <ChartBar>[
                                if (!data.totalCash.isZero)
                                  ChartBar(label: 'Efectivo', value: data.totalCash),
                                if (!data.totalCard.isZero)
                                  ChartBar(label: 'Tarjeta', value: data.totalCard),
                                if (!data.totalTransfer.isZero)
                                  ChartBar(label: 'Transferencia', value: data.totalTransfer),
                                if (!data.totalCredit.isZero)
                                  ChartBar(label: 'Crédito', value: data.totalCredit),
                              ],
                            ),
                          ),
                          const SizedBox(width: AppSpacing.md),
                          Expanded(
                            flex: 2,
                            child: Column(
                              children: <Widget>[
                                _Metric(
                                  label: 'Fondo inicial',
                                  value: currency.money(data.openingAmount),
                                ),
                                _Metric(
                                  label: 'Entradas',
                                  value: currency.money(data.deposits),
                                  color: AppColors.success,
                                ),
                                _Metric(
                                  label: 'Salidas',
                                  value: currency.money(data.totalOutflows),
                                  color: AppColors.orange,
                                ),
                                _Metric(
                                  label: 'Impuestos',
                                  value: currency.money(data.taxTotal),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  error: (Object error, _) => ErrorState(message: '$error'),
                  loading: () => const LoadingState(message: 'Calculando arqueo…'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        SizedBox(
          width: 420,
          child: AppCard(
            title: 'Movimientos del turno',
            subtitle: 'Entradas y salidas de efectivo',
            actions: <Widget>[
              SecondaryButton(
                label: 'Registrar',
                icon: Icons.add,
                onPressed: () => _addMovement(context, ref),
              ),
            ],
            child: movements.when(
              data: (List<CashMovement> list) => list.isEmpty
                  ? const EmptyState(
                      title: 'Sin movimientos',
                      message: 'Registre retiros de efectivo para depósito o entradas '
                          'extraordinarias.',
                      icon: Icons.swap_vert,
                    )
                  : ListView.separated(
                      itemCount: list.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (BuildContext context, int index) {
                        final CashMovement movement = list[index];
                        final bool isIn = movement.type.direction > 0;
                        return ListTile(
                          dense: true,
                          leading: Icon(
                            isIn ? Icons.arrow_downward : Icons.arrow_upward,
                            size: 16,
                            color: isIn ? AppColors.success : AppColors.orange,
                          ),
                          title: Text(movement.type.label),
                          subtitle: Text(
                            '${movement.reason} · ${AppFormat.time(movement.createdAt)}',
                            style: AppTypography.caption,
                          ),
                          trailing: Text(
                            currency.money(movement.amount),
                            style: AppTypography.table.copyWith(
                              fontSize: 12,
                              color: isIn ? AppColors.success : AppColors.orange,
                            ),
                          ),
                        );
                      },
                    ),
              error: (Object error, _) => ErrorState(message: '$error'),
              loading: () => const LoadingState(),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _addMovement(BuildContext context, WidgetRef ref) async {
    final _MovementDraft? draft = await showDialog<_MovementDraft>(
      context: context,
      builder: (BuildContext context) => const _CashMovementDialog(),
    );
    if (draft == null || !context.mounted) return;

    final User? user = ref.read(currentUserProvider);
    if (user == null) return;

    try {
      await ref.read(appDatabaseProvider).cashDao.addMovement(
            session: session,
            type: draft.type,
            amount: draft.amount,
            reason: draft.reason,
            userId: user.id,
            userName: user.fullName,
          );
      if (context.mounted) AppSnack.success(context, 'Movimiento registrado.');
    } on AppFailure catch (failure) {
      if (context.mounted) AppSnack.error(context, failure.message);
    }
  }

  static String _elapsed(DateTime openedAt) {
    final Duration elapsed = DateTime.now().difference(openedAt);
    if (elapsed.inHours > 0) {
      return '${elapsed.inHours} h ${elapsed.inMinutes % 60} min';
    }
    return '${elapsed.inMinutes} min';
  }
}

/// Métrica compacta del arqueo.
class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    this.hint,
    this.color,
    this.emphasis = false,
  });

  final String label;
  final String value;
  final String? hint;
  final Color? color;
  final bool emphasis;

  @override
  Widget build(BuildContext context) => Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                label.toUpperCase(),
                style: AppTypography.label.copyWith(
                  fontSize: 9.5,
                  color: AppColors.textSecondary,
                ),
              ),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  value,
                  style: (emphasis ? AppTypography.display : AppTypography.subtitle)
                      .copyWith(fontSize: emphasis ? 20 : 15, color: color),
                ),
              ),
              if (hint != null)
                Text(
                  hint!,
                  style: AppTypography.caption.copyWith(
                    fontSize: 10,
                    color: AppColors.textHint,
                  ),
                ),
            ],
          ),
        ),
      );
}

/// Apertura del turno.
class _OpenSessionDialog extends StatefulWidget {
  const _OpenSessionDialog();

  @override
  State<_OpenSessionDialog> createState() => _OpenSessionDialogState();
}

class _OpenSessionDialogState extends State<_OpenSessionDialog> {
  final TextEditingController _amount = TextEditingController();

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        icon: const Icon(Icons.lock_open_outlined, color: AppColors.cyan),
        title: const Text('Abrir turno de caja'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                controller: _amount,
                autofocus: true,
                textAlign: TextAlign.right,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: <TextInputFormatter>[
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                ],
                decoration: const InputDecoration(
                  labelText: 'Fondo inicial en efectivo',
                  hintText: '0.00',
                ),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: AppSpacing.sm),
              const HintText(
                'Cuente el efectivo con el que empieza el turno. Este valor es la base '
                'del arqueo y no puede cambiarse después.',
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancelar'),
          ),
          PrimaryButton(
            label: 'Abrir turno',
            icon: Icons.check,
            onPressed: _submit,
          ),
        ],
      );

  void _submit() {
    final Money amount = Money.tryParse(_amount.text) ?? Money.zero;
    if (amount.isNegative) return;
    Navigator.of(context).pop(amount);
  }
}

/// Resultado del cierre (efectivo contado + desglose + nota).
@immutable
class _CloseResult {
  const _CloseResult({
    required this.countedCash,
    required this.denominations,
    this.note,
  });

  final Money countedCash;
  final Map<String, int> denominations;
  final String? note;
}

/// Ventana de cierre con arqueo por denominaciones.
///
/// El conteo por billetes y monedas existe por un motivo práctico: obliga a
/// contar dos veces (una por denominación y otra el total) y evita el error más
/// caro de un POS, cerrar con un número inventado.
class _CloseSessionDialog extends StatefulWidget {
  const _CloseSessionDialog({required this.session, required this.summary});

  final CashSession session;
  final CashSessionSummary summary;

  @override
  State<_CloseSessionDialog> createState() => _CloseSessionDialogState();
}

class _CloseSessionDialogState extends State<_CloseSessionDialog> {
  late final Map<int, TextEditingController> _counts = <int, TextEditingController>{
    for (final int cents in AppConfig.cashDenominationsCents)
      cents: TextEditingController(),
  };
  final TextEditingController _note = TextEditingController();

  @override
  void dispose() {
    for (final TextEditingController controller in _counts.values) {
      controller.dispose();
    }
    _note.dispose();
    super.dispose();
  }

  Money get _counted => _counts.entries.fold(
        Money.zero,
        (Money sum, MapEntry<int, TextEditingController> entry) {
          final int count = int.tryParse(entry.value.text.trim()) ?? 0;
          return sum + Money(entry.key * count);
        },
      );

  @override
  Widget build(BuildContext context) {
    final CurrencyFormat currency = CurrencyFormat();
    final Money expected = widget.summary.expectedCash;
    final Money difference = _counted - expected;

    return AlertDialog(
      contentPadding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      insetPadding: const EdgeInsets.all(AppSpacing.lg),
      title: const Row(
        children: <Widget>[
          Icon(Icons.lock_outline, color: AppColors.deepBlue, size: 22),
          SizedBox(width: AppSpacing.sm),
          Text('Cierre y arqueo de caja'),
        ],
      ),
      content: SizedBox(
        width: 780,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const SectionLabel('Conteo por denominación'),
                  for (final MapEntry<int, TextEditingController> entry in _counts.entries)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        children: <Widget>[
                          SizedBox(
                            width: 90,
                            child: Text(
                              currency.formatCents(entry.key, withSymbol: false),
                              style: AppTypography.table.copyWith(fontSize: 12),
                            ),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          SizedBox(
                            width: 70,
                            child: TextField(
                              controller: entry.value,
                              textAlign: TextAlign.right,
                              keyboardType: TextInputType.number,
                              inputFormatters: <TextInputFormatter>[
                                FilteringTextInputFormatter.digitsOnly,
                              ],
                              decoration: const InputDecoration(
                                isDense: true,
                                hintText: '0',
                              ),
                              onChanged: (_) => setState(() {}),
                            ),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: Text(
                              currency.formatCents(
                                entry.key * (int.tryParse(entry.value.text) ?? 0),
                                withSymbol: false,
                              ),
                              textAlign: TextAlign.right,
                              style: AppTypography.caption,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.lg),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const SectionLabel('Resumen del turno'),
                  _SummaryRow(label: 'Ventas', value: currency.money(widget.summary.grossTotal)),
                  _SummaryRow(
                    label: 'En efectivo',
                    value: currency.money(widget.summary.totalCash),
                  ),
                  _SummaryRow(
                    label: 'Tarjeta / transferencia',
                    value: currency.money(widget.summary.totalCard + widget.summary.totalTransfer),
                  ),
                  _SummaryRow(label: 'Fiado', value: currency.money(widget.summary.totalCredit)),
                  _SummaryRow(
                    label: 'Fondo inicial',
                    value: currency.money(widget.summary.openingAmount),
                  ),
                  _SummaryRow(
                    label: 'Entradas',
                    value: currency.money(widget.summary.deposits),
                  ),
                  _SummaryRow(
                    label: 'Salidas',
                    value: currency.money(widget.summary.totalOutflows),
                  ),
                  const Divider(height: AppSpacing.md),
                  _SummaryRow(
                    label: 'ESPERADO EN CAJÓN',
                    value: currency.money(expected),
                    emphasis: true,
                  ),
                  _SummaryRow(
                    label: 'CONTADO',
                    value: currency.money(_counted),
                    emphasis: true,
                  ),
                  Container(
                    margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    decoration: BoxDecoration(
                      color: difference.isZero
                          ? AppColors.successSurface
                          : difference.isNegative
                              ? AppColors.redSurface
                              : AppColors.orangeSurface,
                      borderRadius: AppRadius.mdAll,
                    ),
                    child: Row(
                      children: <Widget>[
                        Icon(
                          difference.isZero
                              ? Icons.check_circle_outline
                              : Icons.error_outline,
                          size: 18,
                          color: difference.isZero
                              ? AppColors.success
                              : (difference.isNegative ? AppColors.red : AppColors.orange),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            difference.isZero
                                ? 'La caja cuadra exactamente.'
                                : difference.isNegative
                                    ? 'Faltante en caja.'
                                    : 'Sobrante en caja.',
                            style: AppTypography.caption.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Text(
                          currency.money(difference.abs),
                          style: AppTypography.tableStrong.copyWith(fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                  TextField(
                    controller: _note,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Observaciones del cierre (opcional)',
                      hintText: 'Justifique diferencias, incidentes del turno…',
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Seguir operando'),
        ),
        DangerButton(
          label: 'Cerrar turno',
          icon: Icons.lock_outline,
          onPressed: () async {
            final bool confirmed = await ConfirmDialog.show(
              context,
              title: 'Confirmar cierre de turno',
              message: difference.isZero
                  ? 'El arqueo cuadra. Se cerrará el turno y no se podrán registrar '
                      'más ventas en él.'
                  : 'Hay una diferencia de ${currency.money(difference.abs)}. '
                      'El cierre quedará registrado con esa diferencia.',
              confirmLabel: 'Cerrar turno',
              destructive: true,
            );
            if (!confirmed || !mounted) return;
            Navigator.of(context).pop(
              _CloseResult(
                countedCash: _counted,
                denominations: <String, int>{
                  for (final MapEntry<int, TextEditingController> e in _counts.entries)
                    if ((int.tryParse(e.value.text) ?? 0) > 0)
                      '${e.key}': int.parse(e.value.text),
                },
                note: _note.text.trim().isEmpty ? null : _note.text.trim(),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.label,
    required this.value,
    this.emphasis = false,
  });

  final String label;
  final String value;
  final bool emphasis;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                label,
                style: emphasis
                    ? AppTypography.bodyStrong.copyWith(fontSize: 12.5)
                    : AppTypography.caption,
              ),
            ),
            Text(
              value,
              style: (emphasis ? AppTypography.tableStrong : AppTypography.table)
                  .copyWith(fontSize: emphasis ? 13 : 12),
            ),
          ],
        ),
      );
}

/// Borrador de movimiento manual de caja.
@immutable
class _MovementDraft {
  const _MovementDraft({
    required this.type,
    required this.amount,
    required this.reason,
  });

  final CashMovementType type;
  final Money amount;
  final String reason;
}

/// Registro de entrada o salida de efectivo.
class _CashMovementDialog extends StatefulWidget {
  const _CashMovementDialog();

  @override
  State<_CashMovementDialog> createState() => _CashMovementDialogState();
}

class _CashMovementDialogState extends State<_CashMovementDialog> {
  final TextEditingController _amount = TextEditingController();
  final TextEditingController _reason = TextEditingController();
  CashMovementType _type = CashMovementType.withdrawal;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final CurrencyFormat currency = CurrencyFormat();
    return AlertDialog(
      icon: const Icon(Icons.swap_vert, color: AppColors.cyan),
      title: const Text('Movimiento de efectivo'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                for (final CashMovementType type in CashMovementType.values)
                  if (type.isManual)
                    Padding(
                      padding: const EdgeInsets.only(right: AppSpacing.xs),
                      child: ChoiceChip(
                        label: Text(type.label),
                        selected: _type == type,
                        selectedColor: AppColors.deepBlue,
                        labelStyle: AppTypography.caption.copyWith(
                          color: _type == type ? AppColors.white : AppColors.textPrimary,
                        ),
                        onSelected: (_) => setState(() => _type = type),
                      ),
                    ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _amount,
              autofocus: true,
              textAlign: TextAlign.right,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
              ],
              decoration: InputDecoration(
                labelText: 'Importe',
                prefixText: '${currency.symbol} ',
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _reason,
              decoration: const InputDecoration(
                labelText: 'Motivo *',
                hintText: 'Depósito al banco, cambio de sencillo, pago a proveedor…',
              ),
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
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        PrimaryButton(
          label: 'Registrar',
          icon: Icons.check,
          onPressed: () {
            final Money amount = Money.tryParse(_amount.text) ?? Money.zero;
            final String reason = _reason.text.trim();
            if (!amount.isPositive) {
              setState(() => _error = 'El importe debe ser mayor que cero.');
              return;
            }
            if (reason.isEmpty) {
              setState(() => _error = 'Indique el motivo del movimiento.');
              return;
            }
            Navigator.of(context).pop(
              _MovementDraft(type: _type, amount: amount, reason: reason),
            );
          },
        ),
      ],
    );
  }
}
