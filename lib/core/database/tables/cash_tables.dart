import 'package:drift/drift.dart';

import '../converters/app_converters.dart';
import '../../domain/enums.dart';

/// Turnos de caja y movimientos manuales de efectivo.
library;

/// Turno de caja (apertura → cierre).
///
/// Un POS puede operar sin turno abierto en modo "consulta", pero **no puede
/// cobrar en efectivo** sin turno: si no, el arqueo del día es imposible.
@TableIndex(name: 'idx_sessions_uuid', columns: {#uuid}, unique: true)
@TableIndex(name: 'idx_sessions_status', columns: {#status})
@TableIndex(name: 'idx_sessions_device', columns: {#deviceId, #openedAt})
@DataClassName('CashSession')
class CashSessions extends Table {
  IntColumn get id => integer().autoIncrement()();

  TextColumn get uuid => text().withLength(min: 8, max: 64)();

  TextColumn get status => text().map(const CashSessionStatusConverter())();

  /// Cajero que abre el turno.
  IntColumn get openedByUserId => integer().references(Users, #id)();

  TextColumn get openedByUuid => text()();

  TextColumn get openedByName => text()();

  /// Cajero que cierra (puede ser otro: relevo de turno).
  TextColumn get closedByUuid => text().nullable()();

  TextColumn get closedByName => text().nullable()();

  /// Fondo inicial de efectivo (centavos).
  IntColumn get openingAmount => integer().map(const MoneyConverter())();

  /// Efectivo contado físicamente en el arqueo de cierre.
  IntColumn get countedCash =>
      integer().nullable().map(const NullableMoneyConverter())();

  /// Efectivo que el sistema esperaba tener (calculado al cierre).
  IntColumn get expectedCash =>
      integer().nullable().map(const NullableMoneyConverter())();

  /// Diferencia `countedCash - expectedCash`. Positivo = sobrante.
  IntColumn get difference =>
      integer().nullable().map(const NullableMoneyConverter())();

  // --- Totales consolidados del turno (calculados y congelados al cerrar) ---
  IntColumn get salesCount => integer().withDefault(const Constant(0))();

  IntColumn get totalSales => integer().withDefault(const Constant(0)).map(const MoneyConverter())();

  IntColumn get totalCash => integer().withDefault(const Constant(0)).map(const MoneyConverter())();

  IntColumn get totalCard => integer().withDefault(const Constant(0)).map(const MoneyConverter())();

  IntColumn get totalTransfer =>
      integer().withDefault(const Constant(0)).map(const MoneyConverter())();

  IntColumn get totalCredit => integer().withDefault(const Constant(0)).map(const MoneyConverter())();

  IntColumn get totalOther => integer().withDefault(const Constant(0)).map(const MoneyConverter())();

  IntColumn get totalTax => integer().withDefault(const Constant(0)).map(const MoneyConverter())();

  IntColumn get totalDiscount =>
      integer().withDefault(const Constant(0)).map(const MoneyConverter())();

  IntColumn get totalVoids => integer().withDefault(const Constant(0)).map(const MoneyConverter())();

  IntColumn get voidCount => integer().withDefault(const Constant(0))();

  /// Ingresos y retiros manuales del turno.
  IntColumn get totalDeposits =>
      integer().withDefault(const Constant(0)).map(const MoneyConverter())();

  IntColumn get totalWithdrawals =>
      integer().withDefault(const Constant(0)).map(const MoneyConverter())();

  IntColumn get ticketAverage =>
      integer().withDefault(const Constant(0)).map(const MoneyConverter())();

  TextColumn get openNote => text().nullable()();
  TextColumn get closeNote => text().nullable()();

  /// Desglose por denominación del arqueo, en JSON:
  /// `{"1000": 3, "500": 2, "100": 12, "25": 8, ...}` (centavos -> cantidad)
  TextColumn get cashCountJson => text().nullable()();

  DateTimeColumn get openedAt => integer().map(const DateTimeMillisConverter())();
  DateTimeColumn get closedAt =>
      integer().map(const NullableDateTimeMillisConverter()).nullable()();

  DateTimeColumn get createdAt => integer().map(const DateTimeMillisConverter())();
  DateTimeColumn get updatedAt => integer().map(const DateTimeMillisConverter())();
  DateTimeColumn get deletedAt =>
      integer().map(const NullableDateTimeMillisConverter()).nullable()();
  IntColumn get syncVersion => integer().withDefault(const Constant(1))();
  TextColumn get deviceId => text().nullable()();
}

/// Movimientos manuales de efectivo dentro del turno (ingresos y egresos).
///
/// Cada sangría o pago de gasto queda firmado por un usuario.
@TableIndex(name: 'idx_cash_movements_uuid', columns: {#uuid}, unique: true)
@TableIndex(name: 'idx_cash_movements_session', columns: {#sessionId})
@DataClassName('CashMovement')
class CashMovements extends Table {
  IntColumn get id => integer().autoIncrement()();

  TextColumn get uuid => text().withLength(min: 8, max: 64)();

  IntColumn get sessionId => integer().references(CashSessions, #id, onDelete: KeyAction.cascade)();

  TextColumn get sessionUuid => text()();

  TextColumn get type => text().map(const CashMovementTypeConverter())();

  /// Importe (siempre positivo; el signo lo determina `type.direction`).
  IntColumn get amount => integer().map(const MoneyConverter())();

  TextColumn get reason => text()();

  /// Categoría del egreso: `proveedor`, `servicios`, `combustible`...
  TextColumn get category => text().nullable()();

  /// Comprobante o factura asociada al gasto.
  TextColumn get reference => text().nullable()();

  TextColumn get userId => text().nullable()();

  TextColumn get userName => text().nullable()();

  DateTimeColumn get createdAt => integer().map(const DateTimeMillisConverter())();
  DateTimeColumn get updatedAt => integer().map(const DateTimeMillisConverter())();
  DateTimeColumn get deletedAt =>
      integer().map(const NullableDateTimeMillisConverter()).nullable()();
  IntColumn get syncVersion => integer().withDefault(const Constant(1))();
  TextColumn get deviceId => text().nullable()();
}
