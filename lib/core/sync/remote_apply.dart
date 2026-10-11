import 'package:drift/drift.dart';

import '../database/app_database.dart';
import '../domain/enums.dart';
import '../logging/app_logger.dart';
import '../utils/id_generator.dart';
import '../utils/money.dart';
import 'conflict_resolver.dart';
import 'sync_models.dart';

/// Resultado de aplicar un lote de cambios remotos.
class ApplyOutcome {
  const ApplyOutcome({
    required this.applied,
    required this.skipped,
    required this.conflicts,
    required this.reEnqueued,
  });

  static const ApplyOutcome none =
      ApplyOutcome(applied: 0, skipped: 0, conflicts: 0, reEnqueued: 0);

  final int applied;
  final int skipped;
  final int conflicts;
  final int reEnqueued;

  ApplyOutcome operator +(ApplyOutcome other) => ApplyOutcome(
        applied: applied + other.applied,
        skipped: skipped + other.skipped,
        conflicts: conflicts + other.conflicts,
        reEnqueued: reEnqueued + other.reEnqueued,
      );
}

/// Aplica los cambios descargados a la base local, resolviendo conflictos.
///
/// Solo se aplican entidades **maestras** (ver `kPullableEntities`). Los datos
/// transaccionales que bajan del servidor se ignoran de forma explícita: la
/// caja es la autoridad sobre sus propias ventas.
class RemoteApplier {
  RemoteApplier(this._db);

  final AppDatabase _db;

  static const String _scope = 'sync_apply';

  Future<ApplyOutcome> apply(List<RemoteChange> changes) async {
    ApplyOutcome total = ApplyOutcome.none;
    for (final RemoteChange change in changes) {
      try {
        total = total + await _applyOne(change);
      } on Object catch (error, stack) {
        Log.error(
          _scope,
          'No se pudo aplicar el cambio remoto',
          error: error,
          stackTrace: stack,
          data: <String, Object?>{
            'entity': change.entity.storageKey,
            'uuid': change.entityUuid,
          },
        );
        total = total + const ApplyOutcome(applied: 0, skipped: 1, conflicts: 0, reEnqueued: 0);
      }
    }
    return total;
  }

  Future<ApplyOutcome> _applyOne(RemoteChange change) async {
    return switch (change.entity) {
      SyncEntity.product => _applyProduct(change),
      SyncEntity.category => _applyCategory(change),
      SyncEntity.customer => _applyCustomer(change),
      SyncEntity.user => _applyUser(change),
      SyncEntity.company => _applyCompany(change),
      SyncEntity.setting => _applySetting(change),
      // Transaccionales y desconocidas: se ignoran a propósito.
      _ => Future<ApplyOutcome>.value(
          const ApplyOutcome(applied: 0, skipped: 1, conflicts: 0, reEnqueued: 0),
        ),
    };
  }

  /// Decide si el remoto debe ganar para una fila local dada.
  Future<ConflictDecision> _decide({
    required SyncEntity entity,
    required DateTime? localUpdatedAt,
    required String? localDeviceId,
    required RemoteChange change,
    required bool hasPendingLocalChanges,
  }) async =>
      ConflictResolver.decide(
        entity: entity,
        localUpdatedAt: localUpdatedAt,
        localDeviceId: localDeviceId,
        remoteUpdatedAt: change.updatedAt,
        remoteDeviceId: change.payload['device_id'] == null
            ? null
            : '${change.payload['device_id']}',
        hasPendingLocalChanges: hasPendingLocalChanges,
      );

  /// ¿Hay operaciones locales sin subir para esta entidad?
  Future<bool> _hasPending(String entityUuid, SyncEntity entity) async {
    final QueryRow row = await _db.customSelect(
      '''
      SELECT COUNT(*) AS total
        FROM sync_outbox
       WHERE entity_uuid = ? AND entity = ?
         AND status IN ('pending', 'retry', 'in_flight');
      ''',
      variables: <Variable<Object>>[
        Variable.withString(entityUuid),
        Variable.withString(entity.storageKey),
      ],
    ).getSingle();
    return row.read<int>('total') > 0;
  }

  // ---------------------------------------------------------------------------
  // Productos
  // ---------------------------------------------------------------------------

  Future<ApplyOutcome> _applyProduct(RemoteChange change) async {
    final Product? local = await _db.productsDao.findByUuid(change.entityUuid);
    final bool pending = await _hasPending(change.entityUuid, SyncEntity.product);

    final ConflictDecision decision = await _decide(
      entity: SyncEntity.product,
      localUpdatedAt: local?.updatedAt,
      localDeviceId: local?.deviceId,
      change: change,
      hasPendingLocalChanges: pending,
    );

    if (decision.winner == ConflictWinner.local) {
      // Gana la caja: la operación local ya está en la cola, no hay nada que
      // reencolar. Se registra para diagnóstico.
      await _db.syncDao.logEvent(
        level: 'warning',
        message: 'Conflicto de producto resuelto a favor de la caja: '
            '${local?.name ?? change.entityUuid}',
        entity: SyncEntity.product,
        entityUuid: change.entityUuid,
      );
      return const ApplyOutcome(applied: 0, skipped: 0, conflicts: 1, reEnqueued: 0);
    }

    final Map<String, Object?> payload = change.payload;
    final int? categoryId = await _categoryIdFor(payload['category_uuid']);

    final ProductsCompanion companion = ProductsCompanion(
      uuid: Value<String>(change.entityUuid),
      name: Value<String>(_str(payload, 'name', fallback: local?.name ?? 'Producto')),
      sku: Value<String>(_str(payload, 'sku', fallback: '')),
      barcode: Value<String>(_str(payload, 'barcode', fallback: '')),
      unit: Value<ProductUnit>(ProductUnit.fromStorage('${payload['unit']}')),
      price: Value<Money>(Money(_int(payload, 'price_cents'))),
      cost: Value<Money>(Money(_int(payload, 'cost_cents'))),
      taxRateBps: Value<int>(_int(payload, 'tax_rate_bps', fallback: 1600)),
      stock: Value<Quantity>(Quantity(_int(payload, 'stock_milli'))),
      minStock: Value<Quantity>(Quantity(_int(payload, 'min_stock_milli'))),
      trackStock: Value<bool>(_bool(payload, 'track_stock', fallback: true)),
      sellByWeight: Value<bool>(_bool(payload, 'sell_by_weight')),
      categoryId: Value<int?>(categoryId),
      isActive: Value<bool>(_bool(payload, 'is_active', fallback: true)),
      updatedAt: Value<DateTime>(change.updatedAt),
      syncVersion: Value<int>(change.serverVersion),
      deviceId: Value<String?>(payload['device_id'] == null ? null : '${payload['device_id']}'),
      // Un producto que baja del servidor no vuelve a subir por este camino.
      deletedAt: const Value<DateTime?>(null),
    );

    await _db.transaction(() async {
      if (local == null) {
        await _db.into(_db.products).insert(
              companion.copyWith(
                createdAt: Value<DateTime>(change.updatedAt),
              ),
            );
      } else {
        await (_db.update(_db.products)..where((t) => t.uuid.equals(change.entityUuid)))
            .write(companion);
      }
      await _db.syncDao.logEvent(
        level: 'info',
        message: local == null
            ? 'Producto creado desde la nube: ${_str(payload, 'name')}'
            : 'Producto actualizado desde la nube: ${_str(payload, 'name')}',
        entity: SyncEntity.product,
        entityUuid: change.entityUuid,
      );
    });

    return ApplyOutcome(
      applied: 1,
      skipped: 0,
      conflicts: decision.isConflict ? 1 : 0,
      reEnqueued: decision.shouldReenqueueLocal ? 1 : 0,
    );
  }

  Future<int?> _categoryIdFor(Object? categoryUuid) async {
    if (categoryUuid == null) return null;
    final String uuid = '$categoryUuid';
    if (uuid.isEmpty) return null;
    final QueryRow? row = await _db
        .customSelect(
          'SELECT id FROM categories WHERE uuid = ? LIMIT 1;',
          variables: <Variable<Object>>[Variable.withString(uuid)],
        )
        .getSingleOrNull();
    return row?.read<int>('id');
  }

  // ---------------------------------------------------------------------------
  // Categorías
  // ---------------------------------------------------------------------------

  Future<ApplyOutcome> _applyCategory(RemoteChange change) async {
    final QueryRow? local = await _db
        .customSelect(
          'SELECT id, updated_at, device_id FROM categories WHERE uuid = ? LIMIT 1;',
          variables: <Variable<Object>>[Variable.withString(change.entityUuid)],
        )
        .getSingleOrNull();

    final ConflictDecision decision = await _decide(
      entity: SyncEntity.category,
      localUpdatedAt: local == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(local.read<int>('updated_at'), isUtc: true),
      localDeviceId: local?.readNullable<String>('device_id'),
      change: change,
      hasPendingLocalChanges: await _hasPending(change.entityUuid, SyncEntity.category),
    );

    if (decision.winner == ConflictWinner.local) {
      return const ApplyOutcome(applied: 0, skipped: 0, conflicts: 1, reEnqueued: 0);
    }

    final Map<String, Object?> payload = change.payload;
    final CategoriesCompanion companion = CategoriesCompanion(
      uuid: Value<String>(change.entityUuid),
      name: Value<String>(_str(payload, 'name', fallback: 'Categoría')),
      colorHex: Value<String?>(payload['color_hex'] == null ? null : '${payload['color_hex']}'),
      iconName: Value<String?>(payload['icon_name'] == null ? null : '${payload['icon_name']}'),
      sortOrder: Value<int>(_int(payload, 'sort_order')),
      isActive: Value<bool>(_bool(payload, 'is_active', fallback: true)),
      updatedAt: Value<DateTime>(change.updatedAt),
      syncVersion: Value<int>(change.serverVersion),
    );

    if (local == null) {
      await _db.into(_db.categories).insert(
            companion.copyWith(createdAt: Value<DateTime>(change.updatedAt)),
          );
    } else {
      await (_db.update(_db.categories)..where((t) => t.uuid.equals(change.entityUuid)))
          .write(companion);
    }
    return const ApplyOutcome(applied: 1, skipped: 0, conflicts: 0, reEnqueued: 0);
  }

  // ---------------------------------------------------------------------------
  // Clientes
  // ---------------------------------------------------------------------------

  Future<ApplyOutcome> _applyCustomer(RemoteChange change) async {
    final Customer? local = await _db.customersDao.findByUuid(change.entityUuid);
    final ConflictDecision decision = await _decide(
      entity: SyncEntity.customer,
      localUpdatedAt: local?.updatedAt,
      localDeviceId: local?.deviceId,
      change: change,
      hasPendingLocalChanges: await _hasPending(change.entityUuid, SyncEntity.customer),
    );

    if (decision.winner == ConflictWinner.local) {
      await _db.syncDao.logEvent(
        level: 'warning',
        message: 'Conflicto de cliente resuelto a favor de la caja: '
            '${local?.name ?? change.entityUuid}',
        entity: SyncEntity.customer,
        entityUuid: change.entityUuid,
      );
      return const ApplyOutcome(applied: 0, skipped: 0, conflicts: 1, reEnqueued: 0);
    }

    final Map<String, Object?> payload = change.payload;
    final CustomersCompanion companion = CustomersCompanion(
      uuid: Value<String>(change.entityUuid),
      name: Value<String>(_str(payload, 'name', fallback: local?.name ?? 'Cliente')),
      taxId: Value<String>(_str(payload, 'tax_id')),
      phone: Value<String>(_str(payload, 'phone')),
      email: Value<String>(_str(payload, 'email')),
      address: Value<String>(_str(payload, 'address')),
      creditLimit: Value<Money>(Money(_int(payload, 'credit_limit_cents'))),
      discountBps: Value<int>(_int(payload, 'discount_bps')),
      // El saldo local puede incluir fiados aún no sincronizados: no se pisa a
      // ciegas si la caja tiene movimientos pendientes.
      balance: local != null && decision.shouldReenqueueLocal
          ? Value<Money>(local.balance)
          : Value<Money>(Money(_int(payload, 'balance_cents'))),
      loyaltyPoints: Value<int>(_int(payload, 'loyalty_points')),
      isActive: Value<bool>(_bool(payload, 'is_active', fallback: true)),
      updatedAt: Value<DateTime>(change.updatedAt),
      syncVersion: Value<int>(change.serverVersion),
    );

    if (local == null) {
      await _db.into(_db.customers).insert(
            companion.copyWith(createdAt: Value<DateTime>(change.updatedAt)),
          );
    } else {
      await (_db.update(_db.customers)..where((t) => t.uuid.equals(change.entityUuid)))
          .write(companion);
    }
    return const ApplyOutcome(applied: 1, skipped: 0, conflicts: 0, reEnqueued: 0);
  }

  // ---------------------------------------------------------------------------
  // Usuarios (sin PIN: cada caja autentica localmente)
  // ---------------------------------------------------------------------------

  Future<ApplyOutcome> _applyUser(RemoteChange change) async {
    final User? local = await _db.usersDao.findByUuid(change.entityUuid);
    final ConflictDecision decision = await _decide(
      entity: SyncEntity.user,
      localUpdatedAt: local?.updatedAt,
      localDeviceId: local?.deviceId,
      change: change,
      hasPendingLocalChanges: await _hasPending(change.entityUuid, SyncEntity.user),
    );

    if (decision.winner == ConflictWinner.local) {
      return const ApplyOutcome(applied: 0, skipped: 0, conflicts: 1, reEnqueued: 0);
    }

    final Map<String, Object?> payload = change.payload;
    final UsersCompanion companion = UsersCompanion(
      uuid: Value<String>(change.entityUuid),
      username: Value<String>(_str(payload, 'username', fallback: local?.username ?? '')),
      fullName: Value<String>(_str(payload, 'full_name', fallback: local?.fullName ?? 'Usuario')),
      role: Value<UserRole>(UserRole.fromStorage('${payload['role']}')),
      employeeCode: Value<String?>(payload['employee_code'] == null ? null : '${payload['employee_code']}'),
      maxDiscountBps: Value<int>(_int(payload, 'max_discount_bps')),
      isActive: Value<bool>(_bool(payload, 'is_active', fallback: true)),
      updatedAt: Value<DateTime>(change.updatedAt),
      syncVersion: Value<int>(change.serverVersion),
      // pinHash/pinSalt NO se tocan: si el usuario se crea desde la nube,
      // queda sin PIN y el administrador debe asignarlo en la caja.
    );

    if (local == null) {
      await _db.into(_db.users).insert(
            companion.copyWith(createdAt: Value<DateTime>(change.updatedAt)),
          );
    } else {
      await (_db.update(_db.users)..where((t) => t.uuid.equals(change.entityUuid)))
          .write(companion);
    }
    return const ApplyOutcome(applied: 1, skipped: 0, conflicts: 0, reEnqueued: 0);
  }

  // ---------------------------------------------------------------------------
  // Configuración y perfil de empresa
  // ---------------------------------------------------------------------------

  Future<ApplyOutcome> _applyCompany(RemoteChange change) async {
    final Map<String, Object?> payload = change.payload;
    final CompanyProfile? local = await _db.settingsDao.companyProfile();
    final bool remoteIsNewer =
        local == null || change.updatedAt.isAfter(local.updatedAt);

    if (!remoteIsNewer) {
      return const ApplyOutcome(applied: 0, skipped: 0, conflicts: 1, reEnqueued: 0);
    }

    // Se escribe directamente (sin `saveCompanyProfile`): aplicar un cambio que
    // YA viene de la nube no debe reencolarlo y crear un bucle de empuje.
    await _db.into(_db.companyProfiles).insertOnConflictUpdate(
      CompanyProfilesCompanion(
        id: const Value<int>(1),
        legalName: Value<String>(
          _str(payload, 'legal_name', fallback: local?.legalName ?? 'Mi Negocio'),
        ),
        taxId: Value<String>(_str(payload, 'tax_id')),
        address: Value<String>(_str(payload, 'address')),
        phone: Value<String>(_str(payload, 'phone')),
        email: Value<String>(_str(payload, 'email')),
        currencyCode: Value<String>(_str(payload, 'currency_code', fallback: 'NIO')),
        currencySymbol: Value<String>(_str(payload, 'currency_symbol', fallback: r'C$')),
        defaultTaxRateBps: Value<int>(_int(payload, 'default_tax_rate_bps', fallback: 1600)),
        taxIncludedInPrice: Value<bool>(_bool(payload, 'tax_included', fallback: true)),
        taxLabel: Value<String>(_str(payload, 'tax_label', fallback: 'IVA')),
        updatedAt: Value<DateTime>(change.updatedAt),
      ),
    );
    return const ApplyOutcome(applied: 1, skipped: 0, conflicts: 0, reEnqueued: 0);
  }

  Future<ApplyOutcome> _applySetting(RemoteChange change) async {
    final Map<String, Object?> payload = change.payload;
    final String key = _str(payload, 'key', fallback: change.entityUuid);
    if (key.isEmpty) return ApplyOutcome.none;

    final String? localRaw = await _db.settingsDao.rawValue(key);
    final String remoteValue = _str(payload, 'value');

    if (localRaw != null) {
      final QueryRow? row = await _db
          .customSelect(
            'SELECT updated_at FROM app_settings WHERE key = ? LIMIT 1;',
            variables: <Variable<Object>>[Variable.withString(key)],
          )
          .getSingleOrNull();
      final DateTime? localUpdatedAt = row == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(row.read<int>('updated_at'), isUtc: true);
      if (localUpdatedAt != null && !change.updatedAt.isAfter(localUpdatedAt)) {
        return const ApplyOutcome(applied: 0, skipped: 0, conflicts: 1, reEnqueued: 0);
      }
    }

    // Se escribe sin volver a encolar (es un cambio que viene de la nube).
    await _db.into(_db.appSettings).insertOnConflictUpdate(
          AppSettingsCompanion.insert(
            key: key,
            value: remoteValue,
            valueType: Value<String>(_str(payload, 'value_type', fallback: 'string')),
            updatedAt: change.updatedAt,
          ),
        );
    Log.info(_scope, 'Configuración aplicada desde la nube', data: <String, Object?>{'key': key});
    return const ApplyOutcome(applied: 1, skipped: 0, conflicts: 0, reEnqueued: 0);
  }

  // ---------------------------------------------------------------------------
  // Helpers de lectura de JSON (tolerantes: la nube puede cambiar sin romper)
  // ---------------------------------------------------------------------------

  static String _str(
    Map<String, Object?> json,
    String key, {
    String fallback = '',
  }) {
    final Object? value = json[key];
    if (value == null) return fallback;
    final String text = '$value';
    return text.isEmpty ? fallback : text;
  }

  static int _int(Map<String, Object?> json, String key, {int fallback = 0}) {
    final Object? value = json[key];
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? fallback;
    return fallback;
  }

  static bool _bool(Map<String, Object?> json, String key, {bool fallback = false}) {
    final Object? value = json[key];
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) return value == 'true' || value == '1';
    return fallback;
  }

  /// Marca de tiempo de la última escritura de una fila local por uuid.
  Future<DateTime?> localUpdatedAt(String table, String uuid) async {
    final QueryRow? row = await _db
        .customSelect(
          'SELECT updated_at FROM $table WHERE uuid = ? LIMIT 1;',
          variables: <Variable<Object>>[Variable.withString(uuid)],
        )
        .getSingleOrNull();
    return row == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(row.read<int>('updated_at'), isUtc: true);
  }

  /// Utilidad usada por las pruebas y por el modo demostración.
  static String newUuid() => IdGenerator.uuid();
}
