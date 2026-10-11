import 'package:drift/drift.dart';

import '../../domain/enums.dart';
import '../../errors/app_failure.dart';
import '../../utils/id_generator.dart';
import '../../utils/money.dart';
import '../app_database.dart';
import '../tables/catalog_tables.dart';

part 'inventory_dao.g.dart';

/// Inventario: movimientos de kardex y ajuste de existencias.
///
/// **Invariante del sistema:** el stock de un producto solo cambia a través de
/// [adjustStock]. Cada cambio escribe, en la misma transacción:
///   1. la fila de `stock_movements` (con stock anterior y nuevo),
///   2. la actualización de `products.stock`,
///   3. la fila de `sync_outbox` para ambos.
///
/// Gracias a esto, cualquier descuadre de inventario es explicable con el
/// kardex; sin este invariante, un POS se vuelve no auditable.
@DriftAccessor(tables: <Type>[Products, StockMovements])
class InventoryDao extends DatabaseAccessor<AppDatabase> with _$InventoryDaoMixin {
  InventoryDao(AppDatabase db) : super(db);

  /// Aplica un movimiento y devuelve el movimiento registrado.
  ///
  /// [quantity] siempre es positiva; el signo lo aporta [type].direction.
  Future<StockMovement> adjustStock({
    required Product product,
    required StockMovementType type,
    required Quantity quantity,
    Money? unitCost,
    String? reason,
    String? referenceUuid,
    String? referenceType,
    String? userId,
    String? userName,
    bool audit = true,
  }) async {
    if (quantity.isNegative) {
      throw const ValidationFailure(
        message: 'La cantidad del movimiento no puede ser negativa.',
      );
    }
    if (quantity.isZero) {
      throw const ValidationFailure(message: 'La cantidad del movimiento debe ser mayor que cero.');
    }
    if (!product.trackStock) {
      throw BusinessRuleFailure(
        message: 'El producto "${product.name}" no controla inventario.',
        rule: 'product_without_stock_tracking',
      );
    }

    final bool allowNegative = await attachedDatabase.settingsDao
        .boolValue(SettingsKeys.allowNegativeStock, fallback: false);

    final Quantity previous = product.stock;
    final Quantity delta = type.increases ? quantity : -quantity;
    final Quantity next = previous + delta;

    if (next.isNegative && !allowNegative) {
      throw BusinessRuleFailure(
        message: 'Stock insuficiente de "${product.name}". '
            'Disponible: ${previous}. Solicitado: $quantity.',
        rule: 'insufficient_stock',
      );
    }

    final DateTime now = attachedDatabase.now;
    final String uuid = IdGenerator.uuid();
    final Money cost = unitCost ?? product.cost;

    final StockMovement movement = await attachedDatabase.writeWithOutbox<StockMovement>(
      action: () async {
        // 1) Actualización de existencias (UPDATE ... WHERE id, sin leer antes).
        await (update(products)..where((t) => t.id.equals(product.id))).write(
          ProductsCompanion(
            stock: Value<Quantity>(next),
            // El costo se actualiza con el de la última entrada (costo de
            // reposición); el costo promedio ponderado lo calcula el reporte.
            cost: type == StockMovementType.purchase || type == StockMovementType.initial
                ? Value<Money>(cost)
                : const Value<Money>.absent(),
            updatedAt: Value<DateTime>(now),
            syncVersion: Value<int>(product.syncVersion + 1),
          ),
        );

        // 2) Kardex.
        final int id = await into(stockMovements).insert(
          StockMovementsCompanion.insert(
            uuid: uuid,
            productId: product.id,
            productUuid: product.uuid,
            productName: product.name,
            type: type,
            quantity: quantity,
            previousStock: previous,
            newStock: next,
            unitCost: Value<Money?>(unitCost ?? product.cost),
            reason: Value<String?>(reason),
            referenceUuid: Value<String?>(referenceUuid),
            referenceType: Value<String?>(referenceType),
            userId: Value<String?>(userId),
            userName: Value<String?>(userName),
            createdAt: now,
            updatedAt: now,
            deviceId: Value<String?>(attachedDatabase.deviceUuid),
          ),
        );

        // 3) Auditoría solo en movimientos manuales (entradas/ajustes): una
        //    venta ya deja su propia huella en `sales`.
        if (audit && type != StockMovementType.sale) {
          await attachedDatabase.recordAudit(
            entity: 'stock_movement',
            entityUuid: uuid,
            action: type.storageKey,
            userId: userId,
            userName: userName,
            note: reason,
            before: <String, Object?>{'stock_milli': previous.milli},
            after: <String, Object?>{'stock_milli': next.milli},
          );
        }

        // El producto también viaja (su stock cambió): se encola en la MISMA
        // transacción para que stock local y nube nunca diverjan.
        await attachedDatabase.enqueueOutbox(
          entity: SyncEntity.product,
          entityUuid: product.uuid,
          operation: SyncOperation.update,
          payload: <String, Object?>{
            'uuid': product.uuid,
            'stock_milli': next.milli,
            'updated_at': now.toUtc().toIso8601String(),
          },
          lwwTimestamp: now,
          priority: 30,
        );

        return (select(stockMovements)..where((t) => t.id.equals(id))).getSingle();
      },
      entity: SyncEntity.stockMovement,
      entityUuid: uuid,
      operation: SyncOperation.insert,
      payload: _movementPayload(
        uuid: uuid,
        productUuid: product.uuid,
        type: type,
        quantity: quantity,
        previousStock: previous,
        newStock: next,
        unitCost: unitCost ?? product.cost,
        reason: reason,
        referenceUuid: referenceUuid,
        referenceType: referenceType,
        userName: userName,
        createdAt: now,
      ),
      lwwTimestamp: now,
      // Prioridad alta: el inventario refleja las ventas del día.
      priority: 30,
    );

    return movement;
  }

  /// Carga inicial de existencias al crear un producto.
  Future<StockMovement> registerInitialStock({
    required Product product,
    required Quantity quantity,
    Money? unitCost,
  }) =>
      adjustStock(
        product: product,
        type: StockMovementType.initial,
        quantity: quantity,
        unitCost: unitCost,
        reason: 'Carga inicial',
        audit: false,
      );

  /// Entrada de mercancía (compra a proveedor).
  Future<StockMovement> registerEntry({
    required Product product,
    required Quantity quantity,
    Money? unitCost,
    String? supplier,
    String? invoiceReference,
    String? userId,
    String? userName,
  }) =>
      adjustStock(
        product: product,
        type: StockMovementType.purchase,
        quantity: quantity,
        unitCost: unitCost,
        reason: supplier == null ? 'Entrada de mercancía' : 'Compra a $supplier',
        referenceUuid: invoiceReference,
        referenceType: 'purchase',
        userId: userId,
        userName: userName,
      );

  /// Salida por merma, daño o consumo interno.
  Future<StockMovement> registerLoss({
    required Product product,
    required Quantity quantity,
    required String reason,
    String? userId,
    String? userName,
  }) =>
      adjustStock(
        product: product,
        type: StockMovementType.loss,
        quantity: quantity,
        reason: reason,
        userId: userId,
        userName: userName,
      );

  /// Ajuste por conteo físico: fija el stock al valor contado y registra la
  /// diferencia como movimiento (positivo o negativo).
  Future<StockMovement?> applyPhysicalCount({
    required Product product,
    required Quantity counted,
    required String reason,
    String? userId,
    String? userName,
  }) async {
    final Quantity difference = counted - product.stock;
    if (difference.isZero) return null;
    return adjustStock(
      product: product,
      type: difference.isPositive
          ? StockMovementType.adjustmentIn
          : StockMovementType.adjustmentOut,
      quantity: difference.abs,
      reason: reason,
      userId: userId,
      userName: userName,
    );
  }

  /// Descuento de inventario por venta (lo invoca el servicio de cobro dentro
  /// de la transacción de la venta).
  Future<StockMovement> applySaleMovement({
    required Product product,
    required Quantity quantity,
    required String saleUuid,
    String? userName,
  }) =>
      adjustStock(
        product: product,
        type: StockMovementType.sale,
        quantity: quantity,
        reason: 'Venta POS',
        referenceUuid: saleUuid,
        referenceType: 'sale',
        userName: userName,
        audit: false,
      );

  /// Reposición por anulación de venta.
  Future<StockMovement> applySaleReturn({
    required Product product,
    required Quantity quantity,
    required String saleUuid,
    String? userName,
    String? reason,
  }) =>
      adjustStock(
        product: product,
        type: StockMovementType.returnIn,
        quantity: quantity,
        reason: reason ?? 'Anulación de venta',
        referenceUuid: saleUuid,
        referenceType: 'sale_void',
        userName: userName,
        audit: false,
      );

  // ---------------------------------------------------------------------------
  // Consultas (kardex)
  // ---------------------------------------------------------------------------

  Stream<List<StockMovement>> watchMovements({
    int? productId,
    StockMovementType? type,
    DateTime? from,
    DateTime? to,
    int limit = 200,
  }) {
    final SimpleSelectStatement<$StockMovementsTable, StockMovement> query =
        select(stockMovements);
    query
      ..where((t) {
        Expression<bool> predicate = const Constant(true);
        if (productId != null) predicate = predicate & t.productId.equals(productId);
        if (type != null) predicate = predicate & t.type.equalsValue(type);
        if (from != null) {
          predicate = predicate & t.createdAt.isBiggerOrEqualValue(from.toUtc());
        }
        if (to != null) predicate = predicate & t.createdAt.isSmallerOrEqualValue(to.toUtc());
        return predicate;
      })
      ..orderBy(<OrderingTerm Function($StockMovementsTable)>[
        (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
      ])
      ..limit(limit);
    return query.watch();
  }

  Future<List<StockMovement>> movementsForProduct(int productId, {int limit = 100}) =>
      (select(stockMovements)
            ..where((t) => t.productId.equals(productId))
            ..orderBy(<OrderingTerm Function($StockMovementsTable)>[
              (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
            ])
            ..limit(limit))
          .get();

  Future<List<StockMovement>> movementsForReference(String referenceUuid) =>
      (select(stockMovements)..where((t) => t.referenceUuid.equals(referenceUuid))).get();

  /// Rotación de los últimos [days] días por producto (unidades vendidas).
  Future<List<({String productName, int quantityMilli, int movements})>> movementSummary({
    required DateTime from,
    required DateTime to,
    int limit = 50,
  }) async {
    final List<QueryRow> rows = await customSelect(
      '''
      SELECT product_name,
             COALESCE(SUM(quantity), 0) AS qty,
             COUNT(*) AS movements
        FROM stock_movements
       WHERE created_at >= ? AND created_at <= ? AND deleted_at IS NULL
       GROUP BY product_name
       ORDER BY qty DESC
       LIMIT ?;
      ''',
      variables: <Variable<Object>>[
        Variable.withInt(from.toUtc().millisecondsSinceEpoch),
        Variable.withInt(to.toUtc().millisecondsSinceEpoch),
        Variable.withInt(limit),
      ],
    ).get();

    return rows
        .map((QueryRow row) => (
              productName: row.read<String>('product_name'),
              quantityMilli: row.read<int>('qty'),
              movements: row.read<int>('movements'),
            ))
        .toList(growable: false);
  }

  Map<String, Object?> _movementPayload({
    required String uuid,
    required String productUuid,
    required StockMovementType type,
    required Quantity quantity,
    required Quantity previousStock,
    required Quantity newStock,
    required Money unitCost,
    required String? reason,
    required String? referenceUuid,
    required String? referenceType,
    required String? userName,
    required DateTime createdAt,
  }) =>
      <String, Object?>{
        'uuid': uuid,
        'product_uuid': productUuid,
        'type': type.storageKey,
        'quantity_milli': quantity.milli,
        'previous_stock_milli': previousStock.milli,
        'new_stock_milli': newStock.milli,
        'unit_cost_cents': unitCost.cents,
        'reason': reason,
        'reference_uuid': referenceUuid,
        'reference_type': referenceType,
        'user_name': userName,
        'created_at': createdAt.toUtc().toIso8601String(),
      };
}
