import 'package:drift/drift.dart';

import '../../domain/enums.dart';
import '../../utils/money.dart';

/// Convertidores de Drift.
///
/// **Decisión:** los enums se persisten por su `storageKey` explícito
/// (`adjustment_in`, `in_flight`, `stock_movement`), nunca por `index` ni por
/// `name`. Si mañana se renombra un valor del enum en Dart, la base de datos
/// instalada en la caja sigue leyéndose correctamente.
library;

class UserRoleConverter extends TypeConverter<UserRole, String> {
  const UserRoleConverter();

  @override
  UserRole fromSql(String fromDb) => UserRole.fromStorage(fromDb);

  @override
  String toSql(UserRole value) => value.storageKey;
}

class SaleStatusConverter extends TypeConverter<SaleStatus, String> {
  const SaleStatusConverter();

  @override
  SaleStatus fromSql(String fromDb) => SaleStatus.fromStorage(fromDb);

  @override
  String toSql(SaleStatus value) => value.storageKey;
}

class PaymentMethodConverter extends TypeConverter<PaymentMethod, String> {
  const PaymentMethodConverter();

  @override
  PaymentMethod fromSql(String fromDb) => PaymentMethod.fromStorage(fromDb);

  @override
  String toSql(PaymentMethod value) => value.storageKey;
}

class StockMovementTypeConverter extends TypeConverter<StockMovementType, String> {
  const StockMovementTypeConverter();

  @override
  StockMovementType fromSql(String fromDb) => StockMovementType.fromStorage(fromDb);

  @override
  String toSql(StockMovementType value) => value.storageKey;
}

class ProductUnitConverter extends TypeConverter<ProductUnit, String> {
  const ProductUnitConverter();

  @override
  ProductUnit fromSql(String fromDb) => ProductUnit.fromStorage(fromDb);

  @override
  String toSql(ProductUnit value) => value.storageKey;
}

class CashMovementTypeConverter extends TypeConverter<CashMovementType, String> {
  const CashMovementTypeConverter();

  @override
  CashMovementType fromSql(String fromDb) => CashMovementType.fromStorage(fromDb);

  @override
  String toSql(CashMovementType value) => value.storageKey;
}

class CashSessionStatusConverter extends TypeConverter<CashSessionStatus, String> {
  const CashSessionStatusConverter();

  @override
  CashSessionStatus fromSql(String fromDb) => CashSessionStatus.fromStorage(fromDb);

  @override
  String toSql(CashSessionStatus value) => value.storageKey;
}

class SyncEntityConverter extends TypeConverter<SyncEntity, String> {
  const SyncEntityConverter();

  @override
  SyncEntity fromSql(String fromDb) =>
      SyncEntity.tryFromStorage(fromDb) ?? SyncEntity.setting;

  @override
  String toSql(SyncEntity value) => value.storageKey;
}

class NullableSyncEntityConverter extends TypeConverter<SyncEntity?, String?> {
  const NullableSyncEntityConverter();

  @override
  SyncEntity? fromSql(String? fromDb) => SyncEntity.tryFromStorage(fromDb);

  @override
  String? toSql(SyncEntity? value) => value?.storageKey;
}

class SyncOperationConverter extends TypeConverter<SyncOperation, String> {
  const SyncOperationConverter();

  @override
  SyncOperation fromSql(String fromDb) => SyncOperation.fromStorage(fromDb);

  @override
  String toSql(SyncOperation value) => value.storageKey;
}

class SyncStatusConverter extends TypeConverter<SyncStatus, String> {
  const SyncStatusConverter();

  @override
  SyncStatus fromSql(String fromDb) => SyncStatus.fromStorage(fromDb);

  @override
  String toSql(SyncStatus value) => value.storageKey;
}

/// Dinero: `Money` <-> centavos (INTEGER).
class MoneyConverter extends TypeConverter<Money, int> {
  const MoneyConverter();

  @override
  Money fromSql(int fromDb) => Money(fromDb);

  @override
  int toSql(Money value) => value.cents;
}

class NullableMoneyConverter extends TypeConverter<Money?, int?> {
  const NullableMoneyConverter();

  @override
  Money? fromSql(int? fromDb) => fromDb == null ? null : Money(fromDb);

  @override
  int? toSql(Money? value) => value?.cents;
}

/// Cantidad: `Quantity` <-> milésimas de unidad (INTEGER).
class QuantityConverter extends TypeConverter<Quantity, int> {
  const QuantityConverter();

  @override
  Quantity fromSql(int fromDb) => Quantity(fromDb);

  @override
  int toSql(Quantity value) => value.milli;
}

class NullableQuantityConverter extends TypeConverter<Quantity?, int?> {
  const NullableQuantityConverter();

  @override
  Quantity? fromSql(int? fromDb) => fromDb == null ? null : Quantity(fromDb);

  @override
  int? toSql(Quantity? value) => value?.milli;
}

/// Fechas: `DateTime` <-> milisegundos UTC (INTEGER).
///
/// Se almacena en UTC y se convierte a hora local solo en la UI. Evita
/// discrepancias cuando cambia el horario de verano o cuando un equipo tiene
/// la zona horaria mal configurada (situación muy común en cajas reales).
class DateTimeMillisConverter extends TypeConverter<DateTime, int> {
  const DateTimeMillisConverter();

  @override
  DateTime fromSql(int fromDb) => DateTime.fromMillisecondsSinceEpoch(fromDb, isUtc: true);

  @override
  int toSql(DateTime value) => value.toUtc().millisecondsSinceEpoch;
}

class NullableDateTimeMillisConverter extends TypeConverter<DateTime?, int?> {
  const NullableDateTimeMillisConverter();

  @override
  DateTime? fromSql(int? fromDb) => fromDb == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(fromDb, isUtc: true);

  @override
  int? toSql(DateTime? value) => value?.toUtc().millisecondsSinceEpoch;
}
