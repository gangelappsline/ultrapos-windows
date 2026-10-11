import 'package:drift/drift.dart';

import '../../domain/enums.dart';
import '../../errors/app_failure.dart';
import '../../utils/id_generator.dart';
import '../../utils/money.dart';
import '../../domain/sale_totals.dart';
import '../app_database.dart';
import '../tables/sales_tables.dart';

part 'sales_dao.g.dart';

/// Datos necesarios para registrar una venta.
///
/// Es un objeto plano porque el servicio de cobro lo construye **antes** de
/// abrir la transacción: si algo falla al armar el ticket, no se toca la base.
class SaleInsertRequest {
  const SaleInsertRequest({
    required this.folioPrefix,
    required this.status,
    required this.userId,
    required this.userUuid,
    required this.userName,
    required this.items,
    required this.payments,
    required this.customerId,
    required this.customerUuid,
    required this.customerName,
    required this.cashSessionId,
    required this.cashSessionUuid,
    required this.note,
    required this.orderLabel,
    required this.costTotal,
   });

  final String folioPrefix;
  final SaleStatus status;
  final int userId;
  final String userUuid;
  final String userName;
  final List<SaleItemRequest> items;
  final List<SalePaymentRequest> payments;
  final int? customerId;
  final String? customerUuid;
  final String? customerName;
  final int? cashSessionId;
  final String? cashSessionUuid;
  final String? note;
  final String? orderLabel;
  final Money costTotal;
}

/// Línea de venta lista para persistir (cantidades y montos ya calculados).
class SaleItemRequest {
  const SaleItemRequest({
    required this.lineNumber,
    required this.productId,
    required this.productUuid,
    required this.productName,
    required this.sku,
    required this.barcode,
    required this.quantity,
    required this.unitPrice,
    required this.unitCost,
    required this.discountBps,
    required this.discountAmount,
    required this.taxRateBps,
    required this.netTotal,
    required this.taxAmount,
    required this.lineTotal,
    required this.isExempt,
  });

  final int lineNumber;
  final int? productId;
  final String? productUuid;
  final String productName;
  final String sku;
  final String barcode;
  final Quantity quantity;
  final Money unitPrice;
  final Money unitCost;
  final int discountBps;
  final Money discountAmount;
  final int taxRateBps;
  final Money netTotal;
  final Money taxAmount;
  final Money lineTotal;
  final bool isExempt;
}

/// Pago aplicado a la venta.
class SalePaymentRequest {
  const SalePaymentRequest({
    required this.method,
    required this.amount,
    this.changeGiven = Money.zero,
    this.reference,
    this.cardLast4,
  });

  final PaymentMethod method;
  final Money amount;
  final Money changeGiven;
  final String? reference;
  final String? cardLast4;
}

/// Venta con sus líneas y pagos.
typedef SaleDetails = ({Sale sale, List<SaleItem> items, List<SalePayment> payments});

/// Acceso a ventas.
///
/// Las primitivas de escritura ([insertSale], [insertItem], [insertPayment])
/// **no abren transacción propia**: el servicio de cobro las invoca dentro de
/// una única transacción atómica (venta + líneas + pagos + stock + outbox).
@DriftAccessor(tables: <Type>[Sales, SaleItems, SalePayments])
class SalesDao extends DatabaseAccessor<AppDatabase> with _$SalesDaoMixin {
  SalesDao(AppDatabase db) : super(db);

  // ---------------------------------------------------------------------------
  // Escritura
  // ---------------------------------------------------------------------------

  /// Reserva el siguiente folio del dispositivo (atómico, ver SettingsDao).
  Future<String> reserveFolio(String prefix) async {
    final int number = await attachedDatabase.settingsDao.nextFolioNumber(prefix);
    return IdGenerator.folio(prefix, number);
  }

  /// Inserta la cabecera de la venta y devuelve la fila creada.
  Future<Sale> insertSale({
    required SaleInsertRequest request,
    required SaleTotals totals,
  }) async {
    final DateTime now = attachedDatabase.now;
    final String uuid = IdGenerator.uuid();
    final String folio = await reserveFolio(request.folioPrefix);

    final int id = await into(sales).insert(
      SalesCompanion.insert(
        uuid: uuid,
        folioPrefix: request.folioPrefix,
        folioNumber: int.parse(folio.split('-').last),
        folio: folio,
        status: request.status,
        customerId: Value<int?>(request.customerId),
        customerUuid: Value<String?>(request.customerUuid),
        customerName: Value<String?>(request.customerName),
        userId: request.userId,
        userUuid: request.userUuid,
        userName: request.userName,
        cashSessionId: Value<int?>(request.cashSessionId),
        cashSessionUuid: Value<String?>(request.cashSessionUuid),
        subtotal: totals.subtotal,
        discountTotal: totals.discountTotal,
        taxableBase: totals.taxableBase,
        taxTotal: totals.taxTotal,
        total: totals.total,
        paidTotal: totals.paidTotal,
        changeTotal: totals.changeTotal,
        costTotal: Value<Money>(request.costTotal),
        isMixedPayment: Value<bool>(_isMixed(request.payments)),
        isCreditSale: Value<bool>(_hasCredit(request.payments)),
        itemCount: Value<int>(request.items.length),
        note: Value<String?>(request.note),
        orderLabel: Value<String?>(request.orderLabel),
        createdAt: now,
        updatedAt: now,
        deviceId: Value<String?>(attachedDatabase.deviceUuid),
      ),
    );

    return (select(sales)..where((t) => t.id.equals(id))).getSingle();
  }

  Future<SaleItem> insertItem({
    required int saleId,
    required String saleUuid,
    required SaleItemRequest item,
  }) async {
    final DateTime now = attachedDatabase.now;
    final String uuid = IdGenerator.uuid();
    final int id = await into(saleItems).insert(
      SaleItemsCompanion.insert(
        uuid: uuid,
        saleId: saleId,
        saleUuid: saleUuid,
        productId: Value<int?>(item.productId),
        productUuid: Value<String?>(item.productUuid),
        productName: item.productName,
        sku: Value<String>(item.sku),
        barcode: Value<String>(item.barcode),
        quantity: item.quantity,
        unitPrice: item.unitPrice,
        unitCost: Value<Money>(item.unitCost),
        discountBps: Value<int>(item.discountBps),
        discountAmount: Value<Money>(item.discountAmount),
        taxRateBps: Value<int>(item.taxRateBps),
        netTotal: item.netTotal,
        taxAmount: item.taxAmount,
        lineTotal: item.lineTotal,
        isExempt: Value<bool>(item.isExempt),
        lineNumber: item.lineNumber,
        createdAt: now,
        updatedAt: now,
        deviceId: Value<String?>(attachedDatabase.deviceUuid),
      ),
    );
    return (select(saleItems)..where((t) => t.id.equals(id))).getSingle();
  }

  Future<SalePayment> insertPayment({
    required int saleId,
    required String saleUuid,
    required SalePaymentRequest payment,
  }) async {
    final DateTime now = attachedDatabase.now;
    final String uuid = IdGenerator.uuid();
    final int id = await into(salePayments).insert(
      SalePaymentsCompanion.insert(
        uuid: uuid,
        saleId: saleId,
        saleUuid: saleUuid,
        method: payment.method,
        amount: payment.amount,
        changeGiven: Value<Money>(payment.changeGiven),
        reference: Value<String?>(payment.reference),
        cardLast4: Value<String?>(payment.cardLast4),
        createdAt: now,
        updatedAt: now,
        deviceId: Value<String?>(attachedDatabase.deviceUuid),
      ),
    );
    return (select(salePayments)..where((t) => t.id.equals(id))).getSingle();
  }

  /// Encola la venta **como agregado** (cabecera + líneas + pagos en un solo
  /// payload).
  ///
  /// Motivo: el servidor debe poder insertar el ticket completo en una sola
  /// transacción; si se enviaran por separado, una interrupción de red dejaría
  /// ventas sin líneas en la nube.
  Future<void> enqueueSaleAggregate({
    required Sale sale,
    required List<SaleItem> items,
    required List<SalePayment> payments,
    String? opId,
  }) async {
    await attachedDatabase.enqueueOutbox(
      entity: SyncEntity.sale,
      entityUuid: sale.uuid,
      operation: SyncOperation.insert,
      // La venta es lo primero que debe llegar a la nube: prioridad máxima.
      priority: 5,
      payload: <String, Object?>{
        'uuid': sale.uuid,
        'folio': sale.folio,
        'folio_prefix': sale.folioPrefix,
        'folio_number': sale.folioNumber,
        'status': sale.status.storageKey,
        'customer_uuid': sale.customerUuid,
        'customer_name': sale.customerName,
        'user_uuid': sale.userUuid,
        'user_name': sale.userName,
        'cash_session_uuid': sale.cashSessionUuid,
        'subtotal_cents': sale.subtotal.cents,
        'discount_total_cents': sale.discountTotal.cents,
        'taxable_base_cents': sale.taxableBase.cents,
        'tax_total_cents': sale.taxTotal.cents,
        'total_cents': sale.total.cents,
        'paid_total_cents': sale.paidTotal.cents,
        'change_total_cents': sale.changeTotal.cents,
        'cost_total_cents': sale.costTotal.cents,
        'is_mixed_payment': sale.isMixedPayment,
        'is_credit_sale': sale.isCreditSale,
        'item_count': sale.itemCount,
        'note': sale.note,
        'order_label': sale.orderLabel,
        'created_at': sale.createdAt.toUtc().toIso8601String(),
        'updated_at': sale.updatedAt.toUtc().toIso8601String(),
        'device_id': sale.deviceId,
        'items': items
            .map((SaleItem item) => <String, Object?>{
                  'uuid': item.uuid,
                  'line_number': item.lineNumber,
                  'product_uuid': item.productUuid,
                  'product_name': item.productName,
                  'sku': item.sku,
                  'barcode': item.barcode,
                  'quantity_milli': item.quantity.milli,
                  'unit_price_cents': item.unitPrice.cents,
                  'unit_cost_cents': item.unitCost.cents,
                  'discount_bps': item.discountBps,
                  'discount_amount_cents': item.discountAmount.cents,
                  'tax_rate_bps': item.taxRateBps,
                  'net_total_cents': item.netTotal.cents,
                  'tax_amount_cents': item.taxAmount.cents,
                  'line_total_cents': item.lineTotal.cents,
                  'is_exempt': item.isExempt,
                })
            .toList(growable: false),
        'payments': payments
            .map((SalePayment payment) => <String, Object?>{
                  'uuid': payment.uuid,
                  'method': payment.method.storageKey,
                  'amount_cents': payment.amount.cents,
                  'change_given_cents': payment.changeGiven.cents,
                  'reference': payment.reference,
                  'card_last4': payment.cardLast4,
                })
            .toList(growable: false),
      },
      lwwTimestamp: sale.updatedAt,
      opId: opId,
    );
  }

  /// Marca la venta como impresa (evita reimpresiones accidentales).
  Future<void> markPrinted(String saleUuid) async {
    await (update(sales)..where((t) => t.uuid.equals(saleUuid)))
        .write(SalesCompanion(printed: const Value<bool>(true)));
  }

  /// Anula una venta: marca, devuelve stock y audita.
  ///
  /// No se crea una venta espejo: la venta original pasa a estado `voided` y
  /// queda excluida de los totales de caja y reportes, pero visible en el
  /// historial (auditoría fiscal). Las líneas se conservan intactas.
  Future<void> voidSale({
    required Sale sale,
    required String reason,
    required String voidedByUuid,
    required String voidedByName,
    bool restock = true,
  }) async {
    if (sale.status == SaleStatus.voided) {
      throw const BusinessRuleFailure(
        message: 'Esta venta ya fue anulada.',
        rule: 'sale_already_voided',
      );
    }
    final List<SaleItem> items = await itemsFor(sale.id);
    final DateTime now = attachedDatabase.now;

    await attachedDatabase.writeWithOutbox(
      action: () async {
        await (update(sales)..where((t) => t.id.equals(sale.id))).write(
          SalesCompanion(
            status: const Value<SaleStatus>(SaleStatus.voided),
            voidedAt: Value<DateTime>(now),
            voidedByUuid: Value<String?>(voidedByUuid),
            voidedByName: Value<String?>(voidedByName),
            voidReason: Value<String?>(reason),
            updatedAt: Value<DateTime>(now),
            syncVersion: Value<int>(sale.syncVersion + 1),
          ),
        );

        if (restock) {
          for (final SaleItem item in items) {
            if (item.productUuid == null) continue;
            final Product? product =
                await attachedDatabase.productsDao.findByUuid(item.productUuid!);
            if (product == null || !product.trackStock) continue;
            await attachedDatabase.inventoryDao.applySaleReturn(
              product: product,
              quantity: item.quantity,
              saleUuid: sale.uuid,
              userName: voidedByName,
              reason: 'Anulación: $reason',
            );
          }
        }

        await attachedDatabase.recordAudit(
          entity: 'sale',
          entityUuid: sale.uuid,
          action: 'void',
          userName: voidedByName,
          note: reason,
          before: <String, Object?>{'status': sale.status.storageKey},
          after: <String, Object?>{'status': SaleStatus.voided.storageKey},
        );
      },
      entity: SyncEntity.sale,
      entityUuid: sale.uuid,
      operation: SyncOperation.update,
      payload: <String, Object?>{
        'uuid': sale.uuid,
        'status': SaleStatus.voided.storageKey,
        'voided_at': now.toUtc().toIso8601String(),
        'voided_by': voidedByUuid,
        'void_reason': reason,
        'updated_at': now.toUtc().toIso8601String(),
      },
      lwwTimestamp: now,
      priority: 5,
    );
  }

  /// Guarda/actualiza un pedido en espera (mesa, cliente que fue a buscar algo).
  Future<void> holdOrder({
    required SaleDetails? existing,
    required SaleInsertRequest request,
    required SaleTotals totals,
  }) async {
    await transaction(() async {
      if (existing != null) {
        await (delete(saleItems)..where((t) => t.saleId.equals(existing.sale.id))).go();
        await (delete(salePayments)..where((t) => t.saleId.equals(existing.sale.id))).go();
        await (update(sales)..where((t) => t.id.equals(existing.sale.id))).write(
          SalesCompanion(
            subtotal: Value<Money>(totals.subtotal),
            discountTotal: Value<Money>(totals.discountTotal),
            total: Value<Money>(totals.total),
            itemCount: Value<int>(request.items.length),
            orderLabel: Value<String?>(request.orderLabel),
            note: Value<String?>(request.note),
            customerId: Value<int?>(request.customerId),
            customerUuid: Value<String?>(request.customerUuid),
            customerName: Value<String?>(request.customerName),
            updatedAt: Value<DateTime>(attachedDatabase.now),
          ),
        );
        for (final SaleItemRequest item in request.items) {
          await insertItem(saleId: existing.sale.id, saleUuid: existing.sale.uuid, item: item);
        }
      } else {
        final Sale held = await insertSale(request: request, totals: totals);
        for (final SaleItemRequest item in request.items) {
          await insertItem(saleId: held.id, saleUuid: held.uuid, item: item);
        }
      }
    });
  }

  Future<void> deleteHeldOrder(Sale sale) async {
    await transaction(() async {
      await (delete(saleItems)..where((t) => t.saleId.equals(sale.id))).go();
      await (delete(sales)..where((t) => t.id.equals(sale.id))).go();
    });
  }

  // ---------------------------------------------------------------------------
  // Consultas
  // ---------------------------------------------------------------------------

  Future<Sale?> findByUuid(String uuid) =>
      (select(sales)..where((t) => t.uuid.equals(uuid))).getSingleOrNull();

  Future<Sale?> findById(int id) =>
      (select(sales)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<List<SaleItem>> itemsFor(int saleId) => (select(saleItems)
        ..where((t) => t.saleId.equals(saleId))
        ..orderBy(<OrderingTerm Function($SaleItemsTable)>[
          (t) => OrderingTerm(expression: t.lineNumber),
        ]))
      .get();

  Future<List<SalePayment>> paymentsFor(int saleId) =>
      (select(salePayments)..where((t) => t.saleId.equals(saleId))).get();

  Future<SaleDetails?> detailsFor(String saleUuid) async {
    final Sale? sale = await findByUuid(saleUuid);
    if (sale == null) return null;
    return (
      sale: sale,
      items: await itemsFor(sale.id),
      payments: await paymentsFor(sale.id),
    );
  }

  /// Ventas recientes para el historial y la reimpresión de tickets.
  Stream<List<Sale>> watchRecent({
    int limit = 100,
    DateTime? from,
    DateTime? to,
    String? search,
    SaleStatus? status,
    bool excludeHeld = true,
  }) {
    final SimpleSelectStatement<$SalesTable, Sale> query = select(sales);
    query
      ..where((t) {
        Expression<bool> predicate = t.deletedAt.isNull();
        if (excludeHeld && status == null) {
          predicate = predicate & t.status.equalsValue(SaleStatus.completed);
        }
        if (status != null) predicate = predicate & t.status.equalsValue(status);
        if (from != null) predicate = predicate & t.createdAt.isBiggerOrEqualValue(from.toUtc());
        if (to != null) predicate = predicate & t.createdAt.isSmallerOrEqualValue(to.toUtc());
        final String? term = search?.trim();
        if (term != null && term.isNotEmpty) {
          final String pattern = '%${term.toLowerCase()}%';
          predicate = predicate &
              (t.folio.lower().like(pattern) |
                  t.customerName.lower().like(pattern) |
                  t.userName.lower().like(pattern));
        }
        return predicate;
      })
      ..orderBy(<OrderingTerm Function($SalesTable)>[
        (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
      ])
      ..limit(limit);
    return query.watch();
  }

  Future<List<Sale>> recentSales({
    int limit = 100,
    DateTime? from,
    DateTime? to,
  }) =>
      (select(sales)
            ..where((t) {
              Expression<bool> predicate =
                  t.deletedAt.isNull() & t.status.equalsValue(SaleStatus.completed);
              if (from != null) {
                predicate = predicate & t.createdAt.isBiggerOrEqualValue(from.toUtc());
              }
              if (to != null) {
                predicate = predicate & t.createdAt.isSmallerOrEqualValue(to.toUtc());
              }
              return predicate;
            })
            ..orderBy(<OrderingTerm Function($SalesTable)>[
              (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
            ])
            ..limit(limit))
          .get();

  Future<Sale?> lastSale() => (select(sales)
        ..where((t) => t.status.equalsValue(SaleStatus.completed))
        ..orderBy(<OrderingTerm Function($SalesTable)>[
          (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
        ])
        ..limit(1))
      .getSingleOrNull();

  Future<List<Sale>> heldOrders() => (select(sales)
        ..where((t) => t.status.equalsValue(SaleStatus.held) & t.deletedAt.isNull())
        ..orderBy(<OrderingTerm Function($SalesTable)>[
          (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
        ]))
      .get();

  /// Pedidos en espera observables (pantalla de venta: F4).
  Stream<List<Sale>> watchHeldOrders() => (select(sales)
        ..where((t) =>
            t.deletedAt.isNull() & t.status.equalsValue(SaleStatus.held))
        ..orderBy(<OrderingTerm Function($SalesTable)>[
          (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
        ]))
      .watch();

  Stream<int> watchHeldCount() {
    final Expression<int> count = sales.id.count();
    return (selectOnly(sales)
          ..addColumns(<Expression<Object>>[count])
          ..where(sales.status.equalsValue(SaleStatus.held)))
        .watchSingle()
        .map((TypedResult row) => row.read(count) ?? 0);
  }

  Future<List<Sale>> salesForSession(int sessionId) => (select(sales)
        ..where((t) =>
            t.cashSessionId.equals(sessionId) &
            t.deletedAt.isNull() &
            t.status.equalsValue(SaleStatus.completed))
        ..orderBy(<OrderingTerm Function($SalesTable)>[
          (t) => OrderingTerm(expression: t.createdAt),
        ]))
      .get();

  /// Ventas de un cliente (historial de compras).
  Future<List<Sale>> salesForCustomer(String customerUuid, {int limit = 200}) =>
      (select(sales)
            ..where((t) =>
                t.customerUuid.equals(customerUuid) &
                t.deletedAt.isNull() &
                t.status.equalsValue(SaleStatus.completed))
            ..orderBy(<OrderingTerm Function($SalesTable)>[
              (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
            ])
            ..limit(limit))
          .get();

  /// Stream del detalle de una venta (para el modal de reimpresión).
  Stream<Sale?> watchByUuid(String uuid) =>
      (select(sales)..where((t) => t.uuid.equals(uuid))).watchSingleOrNull();

  static bool _isMixed(List<SalePaymentRequest> payments) =>
      payments.map((SalePaymentRequest p) => p.method).toSet().length > 1;

  static bool _hasCredit(List<SalePaymentRequest> payments) =>
      payments.any((SalePaymentRequest p) => p.method == PaymentMethod.credit);
}
