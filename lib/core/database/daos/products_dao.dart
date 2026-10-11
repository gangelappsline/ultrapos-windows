import 'package:drift/drift.dart';

import '../../domain/enums.dart';
import '../../utils/id_generator.dart';
import '../../utils/money.dart';
import '../app_database.dart';
import '../tables/catalog_tables.dart';

part 'products_dao.g.dart';

/// Filtro de consulta del catálogo (lo usa la grilla de venta y el inventario).
/// Orden de la lista de productos.
enum ProductSort {
  name('name', 'Nombre'),
  stockAsc('stock_asc', 'Menos stock primero'),
  priceDesc('price_desc', 'Precio (mayor primero)'),
  updatedDesc('updated_desc', 'Modificados recientemente');

  const ProductSort(this.storageKey, this.label);

  final String storageKey;
  final String label;
}

/// Filtro del catálogo (compartido por la tabla de inventario y los selectores).
class ProductFilter {
  const ProductFilter({
    this.search,
    this.categoryId,
    this.onlyFavorites = false,
    this.onlyLowStock = false,
    this.onlyOutOfStock = false,
    this.includeInactive = false,
    this.sort = ProductSort.name,
    this.limit = 200,
  });

  final String? search;
  final int? categoryId;
  final bool onlyFavorites;
  final bool onlyLowStock;
  final bool onlyOutOfStock;
  final bool includeInactive;
  final ProductSort sort;
  final int limit;

  bool get isEmpty =>
      (search == null || search!.isEmpty) &&
      categoryId == null &&
      !onlyFavorites &&
      !onlyLowStock &&
      !onlyOutOfStock &&
      !includeInactive;

  ProductFilter copyWith({
    String? search,
    int? categoryId,
    bool? onlyFavorites,
    bool? onlyLowStock,
    bool? onlyOutOfStock,
    bool? includeInactive,
    ProductSort? sort,
    int? limit,
    bool clearCategory = false,
    bool clearSearch = false,
  }) {
    return ProductFilter(
      search: clearSearch ? null : (search ?? this.search),
      categoryId: clearCategory ? null : (categoryId ?? this.categoryId),
      onlyFavorites: onlyFavorites ?? this.onlyFavorites,
      onlyLowStock: onlyLowStock ?? this.onlyLowStock,
      onlyOutOfStock: onlyOutOfStock ?? this.onlyOutOfStock,
      includeInactive: includeInactive ?? this.includeInactive,
      sort: sort ?? this.sort,
      limit: limit ?? this.limit,
    );
  }

  /// Igualdad por valor: es la clave de un `StreamProvider.family`, y sin esto
  /// cada reconstrucción crearía una consulta nueva (y una fuga de streams).
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProductFilter &&
          other.search == search &&
          other.categoryId == categoryId &&
          other.onlyFavorites == onlyFavorites &&
          other.onlyLowStock == onlyLowStock &&
          other.onlyOutOfStock == onlyOutOfStock &&
          other.includeInactive == includeInactive &&
          other.sort == sort &&
          other.limit == limit;

  @override
  int get hashCode => Object.hash(
        search,
        categoryId,
        onlyFavorites,
        onlyLowStock,
        onlyOutOfStock,
        includeInactive,
        sort,
        limit,
      );
}

/// Acceso al catálogo: productos y categorías.
@DriftAccessor(tables: <Type>[Products, Categories])
class ProductsDao extends DatabaseAccessor<AppDatabase> with _$ProductsDaoMixin {
  ProductsDao(AppDatabase db) : super(db);

  // ---------------------------------------------------------------------------
  // Consultas
  // ---------------------------------------------------------------------------

  /// Búsqueda del punto de venta: **primero coincidencia exacta** de código de
  /// barras o SKU (lo que envía un lector), después coincidencia parcial por
  /// nombre. Es el camino caliente del POS: debe responder en milisegundos.
  Future<List<Product>> search(String term, {int limit = 40}) async {
    final String query = term.trim();
    if (query.isEmpty) return <Product>[];

    final List<Product> results = <Product>[];
    final Set<String> seen = <String>{};

    // 1) Coincidencia exacta (lector de código de barras / SKU tecleado).
    final List<Product> exact = await (select(products)
          ..where((t) =>
              t.deletedAt.isNull() &
              t.isActive.equals(true) &
              (t.barcode.equals(query) | t.sku.equals(query)))
          ..limit(5))
        .get();
    for (final Product product in exact) {
      if (seen.add(product.uuid)) results.add(product);
    }

    // 2) Coincidencia parcial por nombre / SKU / código de barras.
    final String pattern = '%${query.toLowerCase()}%';
    final List<Product> partial = await (select(products)
          ..where((t) =>
              t.deletedAt.isNull() &
              t.isActive.equals(true) &
              (t.name.lower().like(pattern) |
                  t.sku.lower().like(pattern) |
                  t.barcode.like(pattern)))
          ..orderBy(<OrderingTerm Function($ProductsTable)>[
            (t) => OrderingTerm(expression: t.isFavorite, mode: OrderingMode.desc),
            (t) => OrderingTerm(expression: t.name),
          ])
          ..limit(limit))
        .get();

    for (final Product product in partial) {
      if (seen.add(product.uuid) && results.length < limit) {
        results.add(product);
      }
    }
    return results;
  }

  /// Flujo reactivo del catálogo: la grilla se repinta sola cuando cambia un
  /// precio, un stock o una categoría (incluso si el cambio vino de la nube).
  Stream<List<Product>> watchFiltered(ProductFilter filter) {
    final SimpleSelectStatement<$ProductsTable, Product> query = select(products);
    query.where((t) {
      Expression<bool> predicate = t.deletedAt.isNull();
      if (!filter.includeInactive) {
        predicate = predicate & t.isActive.equals(true);
      }
      if (filter.categoryId != null) {
        predicate = predicate & t.categoryId.equals(filter.categoryId!);
      }
      if (filter.onlyFavorites) {
        predicate = predicate & t.isFavorite.equals(true);
      }
      if (filter.onlyLowStock) {
        predicate = predicate &
            t.trackStock.equals(true) &
            t.minStock.isBiggerThanValue(Quantity.zero) &
            t.stock.isSmallerOrEqual(t.minStock);
      }
      if (filter.onlyOutOfStock) {
        predicate = predicate &
            t.trackStock.equals(true) &
            t.stock.isSmallerOrEqualValue(Quantity.zero);
      }
      final String? search = filter.search?.trim();
      if (search != null && search.isNotEmpty) {
        final String pattern = '%${search.toLowerCase()}%';
        predicate = predicate &
            (t.name.lower().like(pattern) |
                t.sku.lower().like(pattern) |
                t.barcode.like(pattern));
      }
      return predicate;
    });
    // Los productos marcados como favoritos siempre encabezan la lista: es el
    // orden que espera un cajero que vende los mismos 20 artículos todo el día.
    query
      ..orderBy(<OrderingTerm Function($ProductsTable)>[
        (t) => OrderingTerm(expression: t.isFavorite, mode: OrderingMode.desc),
        ...switch (filter.sort) {
          ProductSort.name => <OrderingTerm Function($ProductsTable)>[
              (t) => OrderingTerm(expression: t.name),
            ],
          ProductSort.stockAsc => <OrderingTerm Function($ProductsTable)>[
              (t) => OrderingTerm(expression: t.stock),
              (t) => OrderingTerm(expression: t.name),
            ],
          ProductSort.priceDesc => <OrderingTerm Function($ProductsTable)>[
              (t) => OrderingTerm(expression: t.price, mode: OrderingMode.desc),
            ],
          ProductSort.updatedDesc => <OrderingTerm Function($ProductsTable)>[
              (t) => OrderingTerm(expression: t.updatedAt, mode: OrderingMode.desc),
            ],
        },
      ])
      ..limit(filter.limit);
    return query.watch();
  }

  Future<List<Product>> findByIds(List<int> ids) {
    if (ids.isEmpty) return Future<List<Product>>.value(<Product>[]);
    return (select(products)..where((t) => t.id.isIn(ids))).get();
  }

  Future<Product?> findById(int id) =>
      (select(products)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<Product?> findByUuid(String uuid) =>
      (select(products)..where((t) => t.uuid.equals(uuid))).getSingleOrNull();

  Future<Product?> findByBarcode(String barcode) => (select(products)
        ..where((t) =>
            t.barcode.equals(barcode.trim()) & t.deletedAt.isNull())
        ..limit(1))
      .getSingleOrNull();

  Future<Product?> findBySku(String sku) => (select(products)
        ..where((t) => t.sku.equals(sku.trim()) & t.deletedAt.isNull())
        ..limit(1))
      .getSingleOrNull();

  /// Productos con stock por debajo del mínimo (alerta naranja del dashboard).
  Stream<List<Product>> watchLowStock({int limit = 50}) => (select(products)
        ..where((t) =>
            t.deletedAt.isNull() &
            t.isActive.equals(true) &
            t.trackStock.equals(true) &
            t.minStock.isBiggerThanValue(Quantity.zero) &
            t.stock.isSmallerOrEqual(t.minStock))
        ..orderBy(<OrderingTerm Function($ProductsTable)>[
          (t) => OrderingTerm(expression: t.stock),
        ])
        ..limit(limit))
      .watch();

  Future<List<Product>> lowStock({int limit = 100}) => (select(products)
        ..where((t) =>
            t.deletedAt.isNull() &
            t.isActive.equals(true) &
            t.trackStock.equals(true) &
            t.minStock.isBiggerThanValue(Quantity.zero) &
            t.stock.isSmallerOrEqual(t.minStock))
        ..limit(limit))
      .get();

  Future<int> countActive() async {
    final Expression<int> count = products.id.count();
    final TypedResult row = await (selectOnly(products)
          ..addColumns(<Expression<Object>>[count])
          ..where(products.deletedAt.isNull() & products.isActive.equals(true)))
        .getSingle();
    return row.read(count) ?? 0;
  }

  Stream<int> watchProductCount() {
    final Expression<int> count = products.id.count();
    return (selectOnly(products)
          ..addColumns(<Expression<Object>>[count])
          ..where(products.deletedAt.isNull() & products.isActive.equals(true)))
        .watchSingle()
        .map((TypedResult row) => row.read(count) ?? 0);
  }

  /// Productos cuya existencia es negativa: síntoma de un descuadre que hay
  /// que investigar (venta sin stock, doble descuento, error de carga).
  Future<List<Product>> negativeStock() => (select(products)
        ..where((t) =>
            t.deletedAt.isNull() & t.trackStock.equals(true) & t.stock.isSmallerThanValue(Quantity.zero)))
      .get();

  // ---------------------------------------------------------------------------
  // Escrituras
  // ---------------------------------------------------------------------------

  /// Crea un producto y lo encola para la nube.
  Future<Product> createProduct({
    required String name,
    required Money price,
    String sku = '',
    String barcode = '',
    String? description,
    int? categoryId,
    ProductUnit unit = ProductUnit.unit,
    Money cost = Money.zero,
    int taxRateBps = 1600,
    Quantity stock = Quantity.zero,
    Quantity minStock = Quantity.zero,
    bool trackStock = true,
    bool sellByWeight = false,
    bool isFavorite = false,
    String? imagePath,
  }) async {
    final DateTime now = attachedDatabase.now;
    final String uuid = IdGenerator.uuid();

    return attachedDatabase.writeWithOutbox<Product>(
      action: () async {
        final int id = await into(products).insert(
          ProductsCompanion.insert(
            uuid: uuid,
            name: name.trim(),
            price: price,
            sku: Value<String>(sku.trim()),
            barcode: Value<String>(barcode.trim()),
            description: Value<String?>(description),
            categoryId: Value<int?>(categoryId),
            unit: unit,
            cost: Value<Money>(cost),
            taxRateBps: Value<int>(taxRateBps),
            stock: Value<Quantity>(stock),
            minStock: Value<Quantity>(minStock),
            trackStock: Value<bool>(trackStock),
            sellByWeight: Value<bool>(sellByWeight),
            isFavorite: Value<bool>(isFavorite),
            imagePath: Value<String?>(imagePath),
            createdAt: now,
            updatedAt: now,
            deviceId: Value<String?>(attachedDatabase.deviceUuid),
          ),
        );
        final Product created = (await (select(products)..where((t) => t.id.equals(id))).getSingle());

        // El stock inicial también es un movimiento de kardex: sin él, el
        // inventario arranca sin trazabilidad.
        if (trackStock && stock.isPositive) {
          await attachedDatabase.inventoryDao.registerInitialStock(
            product: created,
            quantity: stock,
            unitCost: cost,
          );
        }
        return created;
      },
      entity: SyncEntity.product,
      entityUuid: uuid,
      operation: SyncOperation.insert,
      payload: buildSyncPayload(
        uuid: uuid,
        sku: sku,
        barcode: barcode,
        name: name,
        unit: unit,
        price: price,
        cost: cost,
        taxRateBps: taxRateBps,
        stock: stock,
        minStock: minStock,
        trackStock: trackStock,
        sellByWeight: sellByWeight,
        categoryId: categoryId,
        isActive: true,
        createdAt: now,
        updatedAt: now,
      ),
      // Los productos tienen prioridad menor que las ventas: primero se
      // concilia el dinero, después el catálogo.
      priority: 20,
    );
  }

  /// Actualiza un producto (parcial: solo los campos provistos).
  Future<void> updateProduct({
    required Product product,
    String? name,
    String? sku,
    String? barcode,
    Object? description = _absent,
    int? categoryId,
    bool clearCategory = false,
    ProductUnit? unit,
    Money? price,
    Money? cost,
    int? taxRateBps,
    Quantity? minStock,
    bool? trackStock,
    bool? sellByWeight,
    bool? isFavorite,
    bool? isActive,
    String? imagePath,
    String? auditNote,
  }) async {
    final DateTime now = attachedDatabase.now;
    final Product updated = product.copyWith(
      name: name == null ? product.name : name.trim(),
      sku: sku == null ? product.sku : sku.trim(),
      barcode: barcode == null ? product.barcode : barcode.trim(),
      description: identical(description, _absent) ? product.description : description as String?,
      categoryId: clearCategory ? null : (categoryId ?? product.categoryId),
      unit: unit ?? product.unit,
      price: price ?? product.price,
      cost: cost ?? product.cost,
      taxRateBps: taxRateBps ?? product.taxRateBps,
      minStock: minStock ?? product.minStock,
      trackStock: trackStock ?? product.trackStock,
      sellByWeight: sellByWeight ?? product.sellByWeight,
      isFavorite: isFavorite ?? product.isFavorite,
      isActive: isActive ?? product.isActive,
      imagePath: imagePath ?? product.imagePath,
      updatedAt: now,
      syncVersion: product.syncVersion + 1,
    );

    await attachedDatabase.writeWithOutbox(
      action: () async {
        await update(products).replace(updated);
        if (auditNote != null || price != null) {
          await attachedDatabase.recordAudit(
            entity: 'product',
            entityUuid: product.uuid,
            action: 'update',
            note: auditNote ?? 'Cambio de precio: ${product.price} -> ${price ?? product.price}',
            before: <String, Object?>{'price_cents': product.price.cents},
            after: <String, Object?>{'price_cents': (price ?? product.price).cents},
          );
        }
      },
      entity: SyncEntity.product,
      entityUuid: product.uuid,
      operation: SyncOperation.update,
      payload: buildSyncPayload(
        uuid: product.uuid,
        sku: updated.sku,
        barcode: updated.barcode,
        name: updated.name,
        unit: updated.unit,
        price: updated.price,
        cost: updated.cost,
        taxRateBps: updated.taxRateBps,
        stock: updated.stock,
        minStock: updated.minStock,
        trackStock: updated.trackStock,
        sellByWeight: updated.sellByWeight,
        categoryId: updated.categoryId,
        isActive: updated.isActive,
        createdAt: updated.createdAt,
        updatedAt: now,
      ),
      lwwTimestamp: now,
      priority: 20,
    );
  }

  /// Baja lógica. Nunca se borra una fila: las ventas históricas la referencian.
  Future<void> softDelete(Product product, {String? reason}) async {
    final DateTime now = attachedDatabase.now;
    await attachedDatabase.writeWithOutbox(
      action: () async {
        await (update(products)..where((t) => t.id.equals(product.id))).write(
          ProductsCompanion(
            deletedAt: Value<DateTime>(now),
            isActive: const Value<bool>(false),
            updatedAt: Value<DateTime>(now),
            syncVersion: Value<int>(product.syncVersion + 1),
          ),
        );
        await attachedDatabase.recordAudit(
          entity: 'product',
          entityUuid: product.uuid,
          action: 'delete',
          note: reason ?? 'Producto dado de baja',
        );
      },
      entity: SyncEntity.product,
      entityUuid: product.uuid,
      operation: SyncOperation.delete,
      payload: <String, Object?>{
        'uuid': product.uuid,
        'deleted_at': now.toUtc().toIso8601String(),
        'is_active': false,
      },
      lwwTimestamp: now,
      priority: 20,
    );
  }

  /// ¿Ya existe otro producto con ese código de barras?
  ///
  /// Se valida **antes** de guardar: dos productos con el mismo código
  /// romperían el escaneo en el punto de venta.
  Future<Product?> findConflictingBarcode(String barcode, {String? excludeUuid}) async {
    if (barcode.trim().isEmpty) return null;
    final Product? found = await findByBarcode(barcode);
    if (found == null || found.uuid == excludeUuid) return null;
    return found;
  }

  // ---------------------------------------------------------------------------
  // Categorías
  // ---------------------------------------------------------------------------

  Stream<List<Category>> watchCategories({bool includeInactive = false}) {
    return (select(categories)
          ..where((t) =>
              t.deletedAt.isNull() &
              (includeInactive ? const Constant(true) : t.isActive.equals(true)))
          ..orderBy(<OrderingTerm Function($CategoriesTable)>[
            (t) => OrderingTerm(expression: t.sortOrder),
            (t) => OrderingTerm(expression: t.name),
          ]))
        .watch();
  }

  Future<List<Category>> categories() => (select(categories)
        ..where((t) => t.deletedAt.isNull())
        ..orderBy(<OrderingTerm Function($CategoriesTable)>[
          (t) => OrderingTerm(expression: t.sortOrder),
        ]))
      .get();

  Future<Category?> categoryById(int id) =>
      (select(categories)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<Category> createCategory({
    required String name,
    String? colorHex,
    String? iconName,
    int sortOrder = 0,
  }) async {
    final DateTime now = attachedDatabase.now;
    final String uuid = IdGenerator.uuid();
    return attachedDatabase.writeWithOutbox<Category>(
      action: () async {
        final int id = await into(categories).insert(
          CategoriesCompanion.insert(
            uuid: uuid,
            name: name.trim(),
            colorHex: Value<String?>(colorHex),
            iconName: Value<String?>(iconName),
            sortOrder: Value<int>(sortOrder),
            createdAt: now,
            updatedAt: now,
            deviceId: Value<String?>(attachedDatabase.deviceUuid),
          ),
        );
        return (select(categories)..where((t) => t.id.equals(id))).getSingle();
      },
      entity: SyncEntity.category,
      entityUuid: uuid,
      operation: SyncOperation.insert,
      payload: <String, Object?>{
        'uuid': uuid,
        'name': name.trim(),
        'color_hex': colorHex,
        'icon_name': iconName,
        'sort_order': sortOrder,
        'is_active': true,
        'created_at': now.toUtc().toIso8601String(),
        'updated_at': now.toUtc().toIso8601String(),
      },
      priority: 20,
    );
  }

  Future<void> updateCategory({
    required Category category,
    String? name,
    String? colorHex,
    String? iconName,
    int? sortOrder,
    bool? isActive,
  }) async {
    final DateTime now = attachedDatabase.now;
    await attachedDatabase.writeWithOutbox(
      action: () => (update(categories)..where((t) => t.id.equals(category.id))).write(
        CategoriesCompanion(
          name: name == null ? const Value.absent() : Value<String>(name.trim()),
          colorHex: colorHex == null ? const Value.absent() : Value<String?>(colorHex),
          iconName: iconName == null ? const Value.absent() : Value<String?>(iconName),
          sortOrder: sortOrder == null ? const Value.absent() : Value<int>(sortOrder),
          isActive: isActive == null ? const Value.absent() : Value<bool>(isActive),
          updatedAt: Value<DateTime>(now),
          syncVersion: Value<int>(category.syncVersion + 1),
        ),
      ),
      entity: SyncEntity.category,
      entityUuid: category.uuid,
      operation: SyncOperation.update,
      payload: <String, Object?>{
        'uuid': category.uuid,
        'name': (name ?? category.name).trim(),
        'color_hex': colorHex ?? category.colorHex,
        'icon_name': iconName ?? category.iconName,
        'sort_order': sortOrder ?? category.sortOrder,
        'is_active': isActive ?? category.isActive,
        'updated_at': now.toUtc().toIso8601String(),
      },
      lwwTimestamp: now,
      priority: 20,
    );
  }

  Future<void> deleteCategory(Category category) async {
    final DateTime now = attachedDatabase.now;
    await attachedDatabase.writeWithOutbox(
      action: () async {
        // Los productos no se borran: quedan sin categoría.
        await (update(products)..where((t) => t.categoryId.equals(category.id)))
            .write(ProductsCompanion(categoryId: const Value<int?>(null), updatedAt: Value<DateTime>(now)));
        await (update(categories)..where((t) => t.id.equals(category.id))).write(
          CategoriesCompanion(
            deletedAt: Value<DateTime>(now),
            isActive: const Value<bool>(false),
            updatedAt: Value<DateTime>(now),
          ),
        );
      },
      entity: SyncEntity.category,
      entityUuid: category.uuid,
      operation: SyncOperation.delete,
      payload: <String, Object?>{
        'uuid': category.uuid,
        'deleted_at': now.toUtc().toIso8601String(),
      },
      lwwTimestamp: now,
      priority: 20,
    );
  }

  // ---------------------------------------------------------------------------
  // Contrato de sincronización (payload hacia la nube)
  // ---------------------------------------------------------------------------

  /// Construye el payload del producto.
  ///
  /// Contrato **explícito** con el backend (no un volcado de columnas): así un
  /// cambio interno de esquema no altera el formato que viaja por la red.
  static Map<String, Object?> buildSyncPayload({
    required String uuid,
    required String sku,
    required String barcode,
    required String name,
    required ProductUnit unit,
    required Money price,
    required Money cost,
    required int taxRateBps,
    required Quantity stock,
    required Quantity minStock,
    required bool trackStock,
    required bool sellByWeight,
    required int? categoryId,
    required bool isActive,
    required DateTime createdAt,
    required DateTime updatedAt,
  }) =>
      <String, Object?>{
        'uuid': uuid,
        'sku': sku.trim(),
        'barcode': barcode.trim(),
        'name': name.trim(),
        'unit': unit.storageKey,
        'price_cents': price.cents,
        'cost_cents': cost.cents,
        'tax_rate_bps': taxRateBps,
        'stock_milli': stock.milli,
        'min_stock_milli': minStock.milli,
        'track_stock': trackStock,
        'sell_by_weight': sellByWeight,
        'category_id': categoryId,
        'is_active': isActive,
        'created_at': createdAt.toUtc().toIso8601String(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
      };

  /// Valor total del inventario a costo y a precio de venta.
  Future<({Money costValue, Money retailValue})> inventoryValuation() async {
    final QueryRow row = await customSelect(
      '''
      SELECT COALESCE(SUM((stock / 1000.0) * cost), 0)  AS cost_cents,
             COALESCE(SUM((stock / 1000.0) * price), 0) AS retail_cents
        FROM products
       WHERE deleted_at IS NULL AND is_active = 1 AND track_stock = 1;
      ''',
    ).getSingle();
    return (
      costValue: Money(MoneyMath.roundHalfUp(row.read<double>('cost_cents'))),
      retailValue: Money(MoneyMath.roundHalfUp(row.read<double>('retail_cents'))),
    );
  }
}

/// Centinela para distinguir "no enviado" de "enviado como nulo" en los
/// métodos de actualización parcial.
const Object _absent = Object();
