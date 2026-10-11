import 'package:drift/drift.dart';

import '../converters/app_converters.dart';
import '../../domain/enums.dart';

/// Clientes y ventas. El corazón transaccional del POS.
library;

/// Clientes. "Consumidor Final" no es un registro: es la ausencia de cliente
/// (`customerId == null`) en la venta.
@TableIndex(name: 'idx_customers_uuid', columns: {#uuid}, unique: true)
@TableIndex(name: 'idx_customers_tax_id', columns: {#taxId})
@TableIndex(name: 'idx_customers_name', columns: {#name})
@TableIndex(name: 'idx_customers_phone', columns: {#phone})
@DataClassName('Customer')
class Customers extends Table {
  IntColumn get id => integer().autoIncrement()();

  TextColumn get uuid => text().withLength(min: 8, max: 64)();

  TextColumn get name => text().withLength(min: 1, max: 160)();

  /// NIT / RUC / RFC. Se permite vacío (consumidor final identificado).
  TextColumn get taxId => text().withDefault(const Constant(''))();

  TextColumn get phone => text().withDefault(const Constant(''))();

  TextColumn get email => text().withDefault(const Constant(''))();

  TextColumn get address => text().withDefault(const Constant(''))();

  /// Límite de crédito autorizado (centavos). Cero = no se le fía.
  IntColumn get creditLimit => integer().withDefault(const Constant(0)).map(const MoneyConverter())();

  /// Saldo pendiente de pago (centavos).
  IntColumn get balance => integer().withDefault(const Constant(0)).map(const MoneyConverter())();

  /// Puntos de fidelidad acumulados.
  IntColumn get loyaltyPoints => integer().withDefault(const Constant(0))();

  /// Descuento permanente del cliente (basis points).
  IntColumn get discountBps => integer().withDefault(const Constant(0))();

  TextColumn get notes => text().nullable()();

  BoolColumn get isActive => boolean().withDefault(const Constant(true))();

  DateTimeColumn get lastPurchaseAt =>
      integer().map(const NullableDateTimeMillisConverter()).nullable()();

  DateTimeColumn get createdAt => integer().map(const DateTimeMillisConverter())();
  DateTimeColumn get updatedAt => integer().map(const DateTimeMillisConverter())();
  DateTimeColumn get deletedAt =>
      integer().map(const NullableDateTimeMillisConverter()).nullable()();
  IntColumn get syncVersion => integer().withDefault(const Constant(1))();
  TextColumn get deviceId => text().nullable()();
}

/// Cabecera de venta (ticket).
///
/// Propiedades críticas para offline-first:
///  * `uuid` es la identidad global e **idempotency key**: si el envío a la nube
///    se reintenta tras un fallo de red, el servidor detecta el mismo uuid y no
///    duplica la venta.
///  * Una venta nunca se borra ni se edita en importes: se **anula**, generando
///    una venta espejo en negativo y devolviendo el stock (auditoría fiscal).
@TableIndex(name: 'idx_sales_uuid', columns: {#uuid}, unique: true)
@TableIndex(name: 'idx_sales_folio', columns: {#folioPrefix, #folioNumber}, unique: true)
@TableIndex(name: 'idx_sales_created', columns: {#createdAt})
@TableIndex(name: 'idx_sales_session', columns: {#cashSessionId})
@TableIndex(name: 'idx_sales_customer', columns: {#customerId})
@TableIndex(name: 'idx_sales_status', columns: {#status})
@DataClassName('Sale')
class Sales extends Table {
  IntColumn get id => integer().autoIncrement()();

  TextColumn get uuid => text().withLength(min: 8, max: 64)();

  /// Prefijo del dispositivo emisor (`A`, `B`...).
  TextColumn get folioPrefix => text()();

  /// Número consecutivo dentro del prefijo.
  IntColumn get folioNumber => integer()();

  /// Folio completo para mostrar e imprimir: `A-000123`.
  TextColumn get folio => text()();

  TextColumn get status => text().map(const SaleStatusConverter())();

  IntColumn get customerId =>
      integer().nullable().references(Customers, #id, onDelete: KeyAction.setNull)();

  /// UUID del cliente: la referencia que viaja a la nube.
  TextColumn get customerUuid => text().nullable()();

  /// Nombre del cliente congelado al momento de la venta.
  TextColumn get customerName => text().nullable()();

  IntColumn get userId => integer().references(Users, #id)();

  TextColumn get userUuid => text()();

  TextColumn get userName => text()();

  IntColumn get cashSessionId =>
      integer().nullable().references(CashSessions, #id, onDelete: KeyAction.setNull)();

  TextColumn get cashSessionUuid => text().nullable()();

  // --- Importes (centavos) ---
  /// Suma de líneas a precio de lista, antes de descuentos.
  IntColumn get subtotal => integer().map(const MoneyConverter())();

  /// Descuento total aplicado (líneas + orden).
  IntColumn get discountTotal => integer().map(const MoneyConverter())();

  /// Base imponible neta (sobre la que se calcula el impuesto).
  IntColumn get taxableBase => integer().map(const MoneyConverter())();

  IntColumn get taxTotal => integer().map(const MoneyConverter())();

  /// Importe final a cobrar.
  IntColumn get total => integer().map(const MoneyConverter())();

  /// Suma entregada por el cliente (puede exceder el total).
  IntColumn get paidTotal => integer().map(const MoneyConverter())();

  /// Vuelto entregado.
  IntColumn get changeTotal => integer().map(const MoneyConverter())();

  /// Costo total de los bienes vendidos (para calcular utilidad sin releer
  /// el catálogo, que puede haber cambiado de costo después).
  IntColumn get costTotal => integer().withDefault(const Constant(0)).map(const MoneyConverter())();

  // --- Cobro ---
  /// `true` si la venta se pagó con más de un método.
  BoolColumn get isMixedPayment => boolean().withDefault(const Constant(false))();

  /// `true` si quedó saldo pendiente (venta a crédito).
  BoolColumn get isCreditSale => boolean().withDefault(const Constant(false))();

  /// Referencia externa (autorización de tarjeta, número de transferencia).
  TextColumn get externalReference => text().nullable()();

  // --- Desnormalizado para el ticket ---
  IntColumn get itemCount => integer().withDefault(const Constant(0))();

  TextColumn get note => text().nullable()();

  /// Orden de compra / mesa / pedido para llevar.
  TextColumn get orderLabel => text().nullable()();

  /// `true` si ya se imprimió el ticket (evita reimpresiones accidentales).
  BoolColumn get printed => boolean().withDefault(const Constant(false))();

  // --- Anulación ---
  DateTimeColumn get voidedAt =>
      integer().map(const NullableDateTimeMillisConverter()).nullable()();
  TextColumn get voidedByUuid => text().nullable()();
  TextColumn get voidedByName => text().nullable()();
  TextColumn get voidReason => text().nullable()();
  TextColumn get voidedSaleUuid => text().nullable()();

  // --- Metadatos ---
  DateTimeColumn get createdAt => integer().map(const DateTimeMillisConverter())();
  DateTimeColumn get updatedAt => integer().map(const DateTimeMillisConverter())();
  DateTimeColumn get deletedAt =>
      integer().map(const NullableDateTimeMillisConverter()).nullable()();
  IntColumn get syncVersion => integer().withDefault(const Constant(1))();
  TextColumn get deviceId => text().nullable()();
}

/// Líneas del ticket.
///
/// Se congela toda la información del producto (nombre, SKU, precio, costo,
/// tasa de impuesto) porque un ticket emitido no puede cambiar jamás, aunque
/// el catálogo se modifique después.
@TableIndex(name: 'idx_items_uuid', columns: {#uuid}, unique: true)
@TableIndex(name: 'idx_items_sale', columns: {#saleId})
@TableIndex(name: 'idx_items_product', columns: {#productId})
@DataClassName('SaleItem')
class SaleItems extends Table {
  IntColumn get id => integer().autoIncrement()();

  TextColumn get uuid => text().withLength(min: 8, max: 64)();

  IntColumn get saleId => integer().references(Sales, #id, onDelete: KeyAction.cascade)();

  TextColumn get saleUuid => text()();

  IntColumn get productId =>
      integer().nullable().references(Products, #id, onDelete: KeyAction.setNull)();

  TextColumn get productUuid => text().nullable()();

  /// Nombre congelado del producto en el momento de la venta.
  TextColumn get productName => text()();

  TextColumn get sku => text().withDefault(const Constant(''))();

  TextColumn get barcode => text().withDefault(const Constant(''))();

  IntColumn get quantity => integer().map(const QuantityConverter())();

  /// Precio unitario de lista aplicado.
  IntColumn get unitPrice => integer().map(const MoneyConverter())();

  /// Costo unitario congelado (para margen histórico).
  IntColumn get unitCost => integer().withDefault(const Constant(0)).map(const MoneyConverter())();

  /// Descuento de línea en basis points.
  IntColumn get discountBps => integer().withDefault(const Constant(0))();

  /// Descuento de línea en importe (complementario a los bps).
  IntColumn get discountAmount => integer().withDefault(const Constant(0)).map(const MoneyConverter())();

  IntColumn get taxRateBps => integer().withDefault(const Constant(0))();

  /// Importe de la línea antes de impuestos.
  IntColumn get netTotal => integer().map(const MoneyConverter())();

  IntColumn get taxAmount => integer().map(const MoneyConverter())();

  /// Importe final de la línea (lo que se muestra en el ticket).
  IntColumn get lineTotal => integer().map(const MoneyConverter())();

  /// Marca de línea exenta de impuesto (producto con `taxRateBps = 0`).
  BoolColumn get isExempt => boolean().withDefault(const Constant(false))();

  IntColumn get lineNumber => integer()();

  DateTimeColumn get createdAt => integer().map(const DateTimeMillisConverter())();
  DateTimeColumn get updatedAt => integer().map(const DateTimeMillisConverter())();
  DateTimeColumn get deletedAt =>
      integer().map(const NullableDateTimeMillisConverter()).nullable()();
  IntColumn get syncVersion => integer().withDefault(const Constant(1))();
  TextColumn get deviceId => text().nullable()();
}

/// Pagos de la venta (uno por método; el pago mixto genera varios).
@TableIndex(name: 'idx_payments_uuid', columns: {#uuid}, unique: true)
@TableIndex(name: 'idx_payments_sale', columns: {#saleId})
@DataClassName('SalePayment')
class SalePayments extends Table {
  IntColumn get id => integer().autoIncrement()();

  TextColumn get uuid => text().withLength(min: 8, max: 64)();

  IntColumn get saleId => integer().references(Sales, #id, onDelete: KeyAction.cascade)();

  TextColumn get saleUuid => text()();

  TextColumn get method => text().map(const PaymentMethodConverter())();

  /// Importe entregado por este método.
  IntColumn get amount => integer().map(const MoneyConverter())();

  /// Vuelto devuelto **de este método** (solo efectivo puede dar vuelto).
  IntColumn get changeGiven =>
      integer().withDefault(const Constant(0)).map(const MoneyConverter())();

  /// Nº de autorización, últimos 4 dígitos de la tarjeta, nº de referencia.
  TextColumn get reference => text().nullable()();

  TextColumn get cardLast4 => text().nullable()();

  DateTimeColumn get createdAt => integer().map(const DateTimeMillisConverter())();
  DateTimeColumn get updatedAt => integer().map(const DateTimeMillisConverter())();
  DateTimeColumn get deletedAt =>
      integer().map(const NullableDateTimeMillisConverter()).nullable()();
  IntColumn get syncVersion => integer().withDefault(const Constant(1))();
  TextColumn get deviceId => text().nullable()();
}
