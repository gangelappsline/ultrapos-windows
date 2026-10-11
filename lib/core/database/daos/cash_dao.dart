import 'package:drift/drift.dart';

import '../../domain/enums.dart';
import '../../errors/app_failure.dart';
import '../../utils/id_generator.dart';
import '../../utils/money.dart';
import '../app_database.dart';
import '../tables/cash_tables.dart';

part 'cash_dao.g.dart';

/// Resumen consolidado de un turno de caja.
///
/// Se calcula **siempre a partir de las ventas y pagos**, no de contadores
/// incrementales: si un contador se desincroniza (por un cierre forzado o un
/// apagón), el arqueo seguiría siendo correcto porque se recalcula de la
/// fuente de verdad. Los contadores de `cash_sessions` solo se congelan al
/// cerrar, para consulta histórica.
class CashSessionSummary {
  const CashSessionSummary({
    required this.sessionUuid,
    required this.salesCount,
    required this.grossTotal,
    required this.netTotal,
    required this.taxTotal,
    required this.discountTotal,
    required this.costTotal,
    required this.totalCash,
    required this.totalCard,
    required this.totalTransfer,
    required this.totalCredit,
    required this.totalOther,
    required this.voidCount,
    required this.voidTotal,
    required this.deposits,
    required this.withdrawals,
    required this.expenses,
    required this.refunds,
    required this.openingAmount,
    this.countedCash,
  });

  final String sessionUuid;
  final int salesCount;

  final Money grossTotal;
  final Money netTotal;
  final Money taxTotal;
  final Money discountTotal;
  final Money costTotal;

  final Money totalCash;
  final Money totalCard;
  final Money totalTransfer;
  final Money totalCredit;
  final Money totalOther;

  final int voidCount;
  final Money voidTotal;

  final Money deposits;
  final Money withdrawals;
  final Money expenses;
  final Money refunds;

  final Money openingAmount;

  /// Solo presente tras el arqueo de cierre.
  final Money? countedCash;

  int get totalTransactionCount => salesCount;

  /// Utilidad bruta estimada del turno (venta neta - costo de lo vendido).
  Money get grossProfit => netTotal - costTotal;

  Money get totalOutflows => withdrawals + expenses + refunds;

  /// Efectivo que debería haber físicamente en el cajón.
  Money get expectedCash =>
      openingAmount + totalCash + deposits - withdrawals - expenses - refunds;

  /// Diferencia del arqueo: positivo = sobrante, negativo = faltante.
  Money? get difference => countedCash == null ? null : countedCash! - expectedCash;

  /// El arqueo cuadra (o aún no se ha contado el efectivo).
  bool get isBalanced => difference?.isZero ?? true;

  /// ¿La diferencia supera la tolerancia permitida por el negocio?
  bool exceedsTolerance(Money tolerance) =>
      difference != null && !isBalanced && difference!.abs > tolerance;

  Money get ticketAverage => salesCount == 0
      ? Money.zero
      : Money(MoneyMath.mulDiv(grossTotal.cents, 1, salesCount));

  /// Cobros por método, para el desglose del reporte de turno.
  Map<PaymentMethod, Money> get byMethod => <PaymentMethod, Money>{
        PaymentMethod.cash: totalCash,
        PaymentMethod.card: totalCard,
        PaymentMethod.transfer: totalTransfer,
        PaymentMethod.credit: totalCredit,
        PaymentMethod.other: totalOther,
      };
}

/// Acceso a turnos de caja y movimientos de efectivo.
@DriftAccessor(tables: <Type>[CashSessions, CashMovements])
class CashDao extends DatabaseAccessor<AppDatabase> with _$CashDaoMixin {
  CashDao(AppDatabase db) : super(db);

  // ---------------------------------------------------------------------------
  // Turno activo
  // ---------------------------------------------------------------------------

  Future<CashSession?> currentSession() => (select(cashSessions)
        ..where((t) =>
            t.status.equalsValue(CashSessionStatus.open) &
            t.deviceId.equalsValue(attachedDatabase.deviceUuid))
        ..orderBy(<OrderingTerm Function($CashSessionsTable)>[
          (t) => OrderingTerm(expression: t.openedAt, mode: OrderingMode.desc),
        ])
        ..limit(1))
      .getSingleOrNull();

  Stream<CashSession?> watchCurrentSession() => (select(cashSessions)
        ..where((t) =>
            t.status.equalsValue(CashSessionStatus.open) &
            t.deviceId.equalsValue(attachedDatabase.deviceUuid))
        ..orderBy(<OrderingTerm Function($CashSessionsTable)>[
          (t) => OrderingTerm(expression: t.openedAt, mode: OrderingMode.desc),
        ])
        ..limit(1))
      .watchSingleOrNull();

  Future<CashSession?> findByUuid(String uuid) =>
      (select(cashSessions)..where((t) => t.uuid.equals(uuid))).getSingleOrNull();

  /// Historial de turnos cerrados (reporte de cierres).
  Stream<List<CashSession>> watchHistory({int limit = 60, DateTime? from}) =>
      (select(cashSessions)
            ..where((t) {
              Expression<bool> predicate = t.deletedAt.isNull();
              if (from != null) {
                predicate = predicate & t.openedAt.isBiggerOrEqualValue(from.toUtc());
              }
              return predicate;
            })
            ..orderBy(<OrderingTerm Function($CashSessionsTable)>[
              (t) => OrderingTerm(expression: t.openedAt, mode: OrderingMode.desc),
            ])
            ..limit(limit))
          .watch();

  // ---------------------------------------------------------------------------
  // Apertura
  // ---------------------------------------------------------------------------

  /// Abre un turno. Falla si ya hay uno abierto en este equipo: dos turnos
  /// simultáneos harían imposible el arqueo.
  Future<CashSession> openSession({
    required Money openingAmount,
    required int userId,
    required String userUuid,
    required String userName,
    String? note,
    DateTime? shiftDate,
  }) async {
    final CashSession? existing = await currentSession();
    if (existing != null) {
      throw BusinessRuleFailure(
        message: 'Ya existe un turno abierto en este equipo (${existing.openedByName}). '
            'Debe cerrarlo antes de abrir otro.',
        rule: 'session_already_open',
      );
    }

    final DateTime now = attachedDatabase.now;
    final String uuid = IdGenerator.uuid();

    return attachedDatabase.writeWithOutbox<CashSession>(
      action: () async {
        final int id = await into(cashSessions).insert(
          CashSessionsCompanion.insert(
            uuid: uuid,
            status: CashSessionStatus.open,
            openedByUserId: userId,
            openedByUuid: userUuid,
            openedByName: userName,
            openingAmount: openingAmount,
            openNote: Value<String?>(note),
            openedAt: shiftDate?.toUtc() ?? now,
            createdAt: now,
            updatedAt: now,
            deviceId: Value<String?>(attachedDatabase.deviceUuid),
          ),
        );
        await attachedDatabase.recordAudit(
          entity: 'cash_session',
          entityUuid: uuid,
          action: 'open',
          userName: userName,
          note: note,
          after: <String, Object?>{'opening_amount_cents': openingAmount.cents},
        );
        return (select(cashSessions)..where((t) => t.id.equals(id))).getSingle();
      },
      entity: SyncEntity.cashSession,
      entityUuid: uuid,
      operation: SyncOperation.insert,
      payload: <String, Object?>{
        'uuid': uuid,
        'status': CashSessionStatus.open.storageKey,
        'opened_by_uuid': userUuid,
        'opened_by_name': userName,
        'opening_amount_cents': openingAmount.cents,
        'opened_at': (shiftDate?.toUtc() ?? now).toIso8601String(),
        'device_id': attachedDatabase.deviceUuid,
        'created_at': now.toUtc().toIso8601String(),
        'updated_at': now.toUtc().toIso8601String(),
      },
      priority: 15,
    );
  }

  // ---------------------------------------------------------------------------
  // Movimientos de efectivo
  // ---------------------------------------------------------------------------

  /// Registra un ingreso, retiro o pago de gasto del turno.
  Future<CashMovement> addMovement({
    required CashSession session,
    required CashMovementType type,
    required Money amount,
    required String reason,
    String? category,
    String? reference,
    required int userId,
    required String userName,
  }) async {
    if (amount.isNegative || amount.isZero) {
      throw const ValidationFailure(
        message: 'El importe del movimiento debe ser mayor que cero.',
      );
    }
    if (!type.isManual) {
      throw ValidationFailure(
        message: 'El tipo "${type.label}" no se captura manualmente.',
        technicalDetail: 'Tipo no manual solicitado desde la UI',
      );
    }
    final DateTime now = attachedDatabase.now;
    final String uuid = IdGenerator.uuid();

    return attachedDatabase.writeWithOutbox<CashMovement>(
      action: () async {
        final int id = await into(cashMovements).insert(
          CashMovementsCompanion.insert(
            uuid: uuid,
            sessionId: session.id,
            sessionUuid: session.uuid,
            type: type,
            amount: amount,
            reason: reason,
            category: Value<String?>(category),
            reference: Value<String?>(reference),
            userId: Value<String?>(session.openedByUuid),
            userName: Value<String?>(userName),
            createdAt: now,
            updatedAt: now,
            deviceId: Value<String?>(attachedDatabase.deviceUuid),
          ),
        );
        await attachedDatabase.recordAudit(
          entity: 'cash_movement',
          entityUuid: uuid,
          action: type.storageKey,
          userId: session.openedByUuid,
          userName: userName,
          note: '$reason (${amount.cents} centavos)',
        );
        return (select(cashMovements)..where((t) => t.id.equals(id))).getSingle();
      },
      entity: SyncEntity.cashMovement,
      entityUuid: uuid,
      operation: SyncOperation.insert,
      payload: <String, Object?>{
        'uuid': uuid,
        'session_uuid': session.uuid,
        'type': type.storageKey,
        'amount_cents': amount.cents,
        'reason': reason,
        'category': category,
        'reference': reference,
        'user_name': userName,
        'created_at': now.toUtc().toIso8601String(),
      },
      priority: 15,
    );
  }

  Stream<List<CashMovement>> watchMovements(int sessionId) => (select(cashMovements)
        ..where((t) => t.sessionId.equals(sessionId) & t.deletedAt.isNull())
        ..orderBy(<OrderingTerm Function($CashMovementsTable)>[
          (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
        ]))
      .watch();

  Future<List<CashMovement>> movements(int sessionId) =>
      (select(cashMovements)..where((t) => t.sessionId.equals(sessionId))).get();

  // ---------------------------------------------------------------------------
  // Resumen y arqueo
  // ---------------------------------------------------------------------------

  /// Calcula el resumen completo del turno desde la fuente de verdad.
  Future<CashSessionSummary> summarize(CashSession session, {Money? countedCash}) async {
    final int sessionId = session.id;

    // 1) Ventas efectivas.
    final QueryRow salesRow = await customSelect(
      '''
      SELECT COUNT(*)                      AS sales_count,
             COALESCE(SUM(total), 0)       AS gross_total,
             COALESCE(SUM(taxable_base), 0) AS net_total,
             COALESCE(SUM(tax_total), 0)   AS tax_total,
             COALESCE(SUM(discount_total), 0) AS discount_total,
             COALESCE(SUM(cost_total), 0)  AS cost_total
        FROM sales
       WHERE cash_session_id = ?
         AND status = 'completed'
         AND deleted_at IS NULL;
      ''',
      variables: <Variable<Object>>[Variable.withInt(sessionId)],
    ).getSingle();

    // 2) Cobros por método (el efectivo se netea con el vuelto entregado).
    final List<QueryRow> paymentRows = await customSelect(
      '''
      SELECT p.method                                  AS method,
             COALESCE(SUM(p.amount - p.change_given), 0) AS net_amount
        FROM sale_payments p
        JOIN sales s ON s.id = p.sale_id
       WHERE s.cash_session_id = ?
         AND s.status = 'completed'
         AND s.deleted_at IS NULL
         AND p.deleted_at IS NULL
       GROUP BY p.method;
      ''',
      variables: <Variable<Object>>[Variable.withInt(sessionId)],
    ).get();

    Money methodTotal(PaymentMethod method) {
      final QueryRow? row = paymentRows
          .cast<QueryRow?>()
          .firstWhere((QueryRow? r) => r?.read<String>('method') == method.storageKey, orElse: () => null);
      return Money(row?.read<int>('net_amount') ?? 0);
    }

    // 3) Anulaciones del turno.
    final QueryRow voidRow = await customSelect(
      '''
      SELECT COUNT(*)                AS void_count,
             COALESCE(SUM(total), 0) AS void_total
        FROM sales
       WHERE cash_session_id = ?
         AND status = 'voided'
         AND deleted_at IS NULL;
      ''',
      variables: <Variable<Object>>[Variable.withInt(sessionId)],
    ).getSingle();

    // 4) Movimientos manuales de efectivo.
    final QueryRow movementRow = await customSelect(
      '''
      SELECT COALESCE(SUM(CASE WHEN type = 'deposit' THEN amount ELSE 0 END), 0)                        AS deposits,
             COALESCE(SUM(CASE WHEN type = 'withdrawal' THEN amount ELSE 0 END), 0)                     AS withdrawals,
             COALESCE(SUM(CASE WHEN type = 'expense' THEN amount ELSE 0 END), 0)                        AS expenses,
             COALESCE(SUM(CASE WHEN type IN ('refund') THEN amount ELSE 0 END), 0)                      AS refunds
        FROM cash_movements
       WHERE session_id = ? AND deleted_at IS NULL;
      ''',
      variables: <Variable<Object>>[Variable.withInt(sessionId)],
    ).getSingle();

    return CashSessionSummary(
      sessionUuid: session.uuid,
      salesCount: salesRow.read<int>('sales_count'),
      grossTotal: Money(salesRow.read<int>('gross_total')),
      netTotal: Money(salesRow.read<int>('net_total')),
      taxTotal: Money(salesRow.read<int>('tax_total')),
      discountTotal: Money(salesRow.read<int>('discount_total')),
      costTotal: Money(salesRow.read<int>('cost_total')),
      totalCash: methodTotal(PaymentMethod.cash),
      totalCard: methodTotal(PaymentMethod.card),
      totalTransfer: methodTotal(PaymentMethod.transfer),
      totalCredit: methodTotal(PaymentMethod.credit),
      totalOther: methodTotal(PaymentMethod.other),
      voidCount: voidRow.read<int>('void_count'),
      voidTotal: Money(voidRow.read<int>('void_total')),
      deposits: Money(movementRow.read<int>('deposits')),
      withdrawals: Money(movementRow.read<int>('withdrawals')),
      expenses: Money(movementRow.read<int>('expenses')),
      refunds: Money(movementRow.read<int>('refunds')),
      openingAmount: session.openingAmount,
      countedCash: countedCash,
    );
  }

  /// Efectivo esperado en el cajón (previsualización durante el turno).
  Future<Money> expectedCash(CashSession session) async {
    final CashSessionSummary summary = await summarize(session);
    return summary.expectedCash;
  }

  /// Cierra el turno con arqueo. Congela los totales en la fila del turno.
  Future<CashSession> closeSession({
    required CashSession session,
    required Money countedCash,
    required int userId,
    required String userUuid,
    required String userName,
    String? note,
    Map<String, int>? denominations,
  }) async {
    if (session.status == CashSessionStatus.closed) {
      throw const BusinessRuleFailure(
        message: 'Este turno ya está cerrado.',
        rule: 'session_already_closed',
      );
    }
    final CashSessionSummary summary =
        await summarize(session, countedCash: countedCash);
    final Money difference = summary.difference ?? Money.zero;
    final DateTime now = attachedDatabase.now;

    return attachedDatabase.writeWithOutbox<CashSession>(
      action: () async {
        await (update(cashSessions)..where((t) => t.id.equals(session.id))).write(
          CashSessionsCompanion(
            status: const Value<CashSessionStatus>(CashSessionStatus.closed),
            closedAt: Value<DateTime>(now),
            closedByUuid: Value<String?>(userUuid),
            closedByName: Value<String?>(userName),
            countedCash: Value<Money?>(countedCash),
            expectedCash: Value<Money?>(summary.expectedCash),
            difference: Value<Money?>(difference),
            salesCount: Value<int>(summary.salesCount),
            totalSales: Value<Money>(summary.grossTotal),
            totalCash: Value<Money>(summary.totalCash),
            totalCard: Value<Money>(summary.totalCard),
            totalTransfer: Value<Money>(summary.totalTransfer),
            totalCredit: Value<Money>(summary.totalCredit),
            totalOther: Value<Money>(summary.totalOther),
            totalTax: Value<Money>(summary.taxTotal),
            totalDiscount: Value<Money>(summary.discountTotal),
            totalVoids: Value<Money>(summary.voidTotal),
            voidCount: Value<int>(summary.voidCount),
            totalDeposits: Value<Money>(summary.deposits),
            totalWithdrawals: Value<Money>(summary.withdrawals + summary.expenses),
            ticketAverage: Value<Money>(summary.ticketAverage),
            closeNote: Value<String?>(note),
            cashCountJson: Value<String?>(_denominationsToJson(denominations)),
            updatedAt: Value<DateTime>(now),
            syncVersion: Value<int>(session.syncVersion + 1),
          ),
        );
        await attachedDatabase.recordAudit(
          entity: 'cash_session',
          entityUuid: session.uuid,
          action: 'close',
          userId: userUuid,
          userName: userName,
          note: note,
          after: <String, Object?>{
            'counted_cash_cents': countedCash.cents,
            'expected_cash_cents': summary.expectedCash.cents,
            'difference_cents': difference.cents,
            'sales_count': summary.salesCount,
          },
        );
        return (select(cashSessions)..where((t) => t.id.equals(session.id))).getSingle();
      },
      entity: SyncEntity.cashSession,
      entityUuid: session.uuid,
      operation: SyncOperation.update,
      payload: <String, Object?>{
        'uuid': session.uuid,
        'status': CashSessionStatus.closed.storageKey,
        'closed_at': now.toUtc().toIso8601String(),
        'closed_by_uuid': userUuid,
        'closed_by_name': userName,
        'counted_cash_cents': countedCash.cents,
        'expected_cash_cents': summary.expectedCash.cents,
        'difference_cents': difference.cents,
        'sales_count': summary.salesCount,
        'total_sales_cents': summary.grossTotal.cents,
        'total_cash_cents': summary.totalCash.cents,
        'total_card_cents': summary.totalCard.cents,
        'total_transfer_cents': summary.totalTransfer.cents,
        'total_credit_cents': summary.totalCredit.cents,
        'total_tax_cents': summary.taxTotal.cents,
        'total_discount_cents': summary.discountTotal.cents,
        'void_count': summary.voidCount,
        'void_total_cents': summary.voidTotal.cents,
        'close_note': note,
        'updated_at': now.toUtc().toIso8601String(),
      },
      lwwTimestamp: now,
      priority: 15,
    );
  }

  /// Desglose del arqueo por denominación, en JSON (`centavos -> cantidad`).
  static String? _denominationsToJson(Map<String, int>? denominations) {
    if (denominations == null || denominations.isEmpty) return null;
    final StringBuffer buffer = StringBuffer('{');
    bool first = true;
    for (final MapEntry<String, int> entry in denominations.entries) {
      if (!first) buffer.write(',');
      first = false;
      buffer.write('"${entry.key}":${entry.value}');
    }
    buffer.write('}');
    return buffer.toString();
  }
}
