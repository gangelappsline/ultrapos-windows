import 'package:drift/drift.dart';

import '../../domain/enums.dart';
import '../converters/app_converters.dart';

/// Catálogo: categorías, productos y kardex de inventario.
library;

/// Categorías de producto (agrupan la grilla de venta rápida).
@TableIndex(name: 'idx_categories_uuid', columns: {#uuid}, unique: true)
@DataClassName('Category')
class Categories extends Table {
  IntColumn get id => integer().autoIncrement()();

  TextColumn get uuid => text().withLength(min: 8, max: 64)();

  TextColumn get name => text().withLength(min: 1, max: 80)();

  /// Color en formato ARGB hex (`FF00AEEF`) para pintar el chip de categoría.
  TextColumn get colorHex => text().nullable()();

  /// Icono Material por nombre (`local_bar`, `restaurant`...).
  TextColumn get iconName => text().nullable()();

  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  BoolColumn get isActive => boolean().withDefault(const Constant(true))();

  DateTimeColumn get createdAt => integer().map(const DateTimeMillisConverter())();
  DateTimeColumn get updatedAt => integer().map(const DateTimeMillisConverter())();
  DateTimeColumn get deletedAt =>
      integer().map(const NullableDateTimeMillisConverter()).nullable()();
  IntColumn get syncVersion => integer().withDefault(const Constant(1))();
  TextColumn get deviceId => text().nullable()();
}

/// Productos.
///
/// * `price` y `cost` se guardan en **centavos** (ver `core/utils/money.dart`).
/// * `stock` se guarda en **milésimas de unidad** para soportar venta por peso.
/// * `barcode` y `sku` son únicos entre productos activos; el buscador del
///   punto de venta golpea esos índices primero (lectura de scanner = 1 ms).
@TableIndex(name: 'idx_products_uuid', columns: {#uuid}, unique: true)
@TableIndex(name: 'idx_products_barcode', columns: {#barcode})
@TableIndex(name: 'idx_products_sku', columns: {#sku})
@TableIndex(name: 'idx_products_name', columns: {#name})
@TableIndex(name: 'idx_products_category', columns: {#categoryId})
@TableIndex(name: 'idx_products_active', columns: {#isActive, #deletedAt})
@DataClassName('Product')
class Products extends Table {
  IntColumn get id => integer().autoIncrement()();

  TextColumn get uuid => text().withLength(min: 8, max: 64)();

  /// Código interno / SKU. Puede repetirse solo si está vacío ('' no es único).
  TextColumn get sku => text().withDefault(const Constant(''))();

  /// Código de barras EAN/UPC/code128 leído por el scanner.
  TextColumn get barcode => text().withDefault(const Constant(''))();

  TextColumn get name => text().withLength(min: 1, max: 160)();

  TextColumn get description => text().nullable()();

  IntColumn get categoryId =>
      integer().nullable().references(Categories, #id, onDelete: KeyAction.setNull)();

  /// Unidad de venta (unidad, kg, litro, servicio...).
  TextColumn get unit => text().map(const ProductUnitConverter())();

  /// Precio de venta unitario, impuestos incluidos o no según la empresa.
  IntColumn get price => integer().map(const MoneyConverter())();

  /// Costo de compra (para margen y valoración de inventario).
  IntColumn get cost => integer().withDefault(const Constant(0)).map(const MoneyConverter())();

  /// Tasa de impuesto del producto en basis points (permite exentos = 0).
  IntColumn get taxRateBps => integer().withDefault(const Constant(1600))();

  /// Existencias actuales en milésimas de unidad.
  IntColumn get stock => integer().withDefault(const Constant(0)).map(const QuantityConverter())();

  /// Umbral de alerta de stock bajo (milésimas). El dashboard pinta en naranja
  /// todo producto cuyo stock esté por debajo de este valor.
  IntColumn get minStock =>
      integer().withDefault(const Constant(0)).map(const QuantityConverter())();

  /// Descuenta inventario al vender. `false` para servicios y combos libres.
  BoolColumn get trackStock => boolean().withDefault(const Constant(true))();

  /// Se vende por peso/medida: habilita cantidad decimal en el carrito.
  BoolColumn get sellByWeight => boolean().withDefault(const Constant(false))();

  /// Botón de acceso rápido en la grilla de venta.
  BoolColumn get isFavorite => boolean().withDefault(const Constant(false))();

  BoolColumn get isActive => boolean().withDefault(const Constant(true))();

  /// Ruta local de la imagen (opcional).
  TextColumn get imagePath => text().nullable()();

  DateTimeColumn get createdAt => integer().map(const DateTimeMillisConverter())();
  DateTimeColumn get updatedAt => integer().map(const DateTimeMillisConverter())();
  DateTimeColumn get deletedAt =>
      integer().map(const NullableDateTimeMillisConverter()).nullable()();
  IntColumn get syncVersion => integer().withDefault(const Constant(1))();
  TextColumn get deviceId => text().nullable()();
}

/// Kardex: **toda** variación de stock queda registrada aquí.
///
/// Regla de negocio innegociable: `products.stock` nunca se modifica sin
/// insertar antes un movimiento con el valor anterior y el nuevo. Es la única
/// forma de explicar un descuadre de inventario meses después.
@TableIndex(name: 'idx_movements_uuid', columns: {#uuid}, unique: true)
@TableIndex(name: 'idx_movements_product', columns: {#productId, #createdAt})
@TableIndex(name: 'idx_movements_reference', columns: {#referenceUuid})
@TableIndex(name: 'idx_movements_created', columns: {#createdAt})
@DataClassName('StockMovement')
class StockMovements extends Table {
  IntColumn get id => integer().autoIncrement()();

  TextColumn get uuid => text().withLength(min: 8, max: 64)();

  IntColumn get productId => integer().references(Products, #id)();

  /// UUID del producto (para sincronizar sin depender del id local).
  TextColumn get productUuid => text()();

  /// Nombre del producto congelado en el momento del movimiento.
  TextColumn get productName => text()();

  TextColumn get type => text().map(const StockMovementTypeConverter())();

  /// Cantidad movida (siempre positiva; el signo lo da `type.direction`).
  IntColumn get quantity => integer().map(const QuantityConverter())();

  IntColumn get previousStock => integer().map(const QuantityConverter())();

  IntColumn get newStock => integer().map(const QuantityConverter())();

  /// Costo unitario del lote (para promedio ponderado en entradas).
  IntColumn get unitCost => integer().nullable().map(const NullableMoneyConverter())();

  /// Motivo textual del ajuste.
  TextColumn get reason => text().nullable()();

  /// Documento origen: `sale:<uuid>`, `purchase:<uuid>`...
  TextColumn get referenceUuid => text().nullable()();

  TextColumn get referenceType => text().nullable()();

  TextColumn get userId => text().nullable()();

  TextColumn get userName => text().nullable()();

  DateTimeColumn get createdAt => integer().map(const DateTimeMillisConverter())();

  DateTimeColumn get updatedAt => integer().map(const DateTimeMillisConverter())();
  DateTimeColumn get deletedAt =>
      integer().map(const NullableDateTimeMillisConverter()).nullable()();
  IntColumn get syncVersion => integer().withDefault(const Constant(1))();
  TextColumn get deviceId => text().nullable()();
}
