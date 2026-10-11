import 'package:drift/drift.dart';

import '../config/app_config.dart';
import '../domain/enums.dart';
import '../utils/money.dart';
import '../logging/app_logger.dart';
import '../utils/id_generator.dart';
import 'daos/cash_dao.dart';
import 'daos/customers_dao.dart';
import 'daos/inventory_dao.dart';
import 'daos/products_dao.dart';
import 'daos/reports_dao.dart';
import 'daos/sales_dao.dart';
import 'daos/settings_dao.dart';
import 'daos/sync_dao.dart';
import 'daos/users_dao.dart';
import 'tables/cash_tables.dart';
import 'tables/catalog_tables.dart';
import 'tables/sales_tables.dart';
import 'tables/sync_tables.dart';
import 'tables/system_tables.dart';

// El código de estas clases lo genera build_runner:
//   dart run build_runner build --delete-conflicting-outputs
part 'app_database.g.dart';

/// Base de datos local de UltraPOS (SQLite vía Drift).
///
/// Contrato de arquitectura offline-first que cumplen TODOS los DAOs:
///
///  1. Toda escritura ocurre dentro de una transacción SQLite.
///  2. Junto a la escritura de negocio se inserta la fila de `sync_outbox`
///     (**Transactional Outbox**), de modo que la operación nunca puede
///     "perderse" entre el disco y la nube.
///  3. Toda mutación sensible deja rastro en `audit_logs`.
///  4. Los borrados son lógicos (`deletedAt`): un POS no borra historia.
@DriftDatabase(
  tables: <Type>[
    // Sistema
    Users,
    AppSettings,
    CompanyProfiles,
    DocumentSequences,
    AuditLogs,
    Devices,
    // Catálogo e inventario
    Categories,
    Products,
    StockMovements,
    // Clientes y ventas
    Customers,
    Sales,
    SaleItems,
    SalePayments,
    // Caja
    CashSessions,
    CashMovements,
    // Sincronización
    SyncOutbox,
    SyncCursors,
    SyncEvents,
  ],
  daos: <Type>[
    UsersDao,
    SettingsDao,
    ProductsDao,
    InventoryDao,
    CustomersDao,
    SalesDao,
    CashDao,
    ReportsDao,
    SyncDao,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(
    QueryExecutor executor, {
    required this.deviceUuid,
    this.deviceName = 'CAJA',
    this.clock,
  }) : super(executor);

  /// Identificador de esta instalación (se estampa en cada fila sincronizada).
  final String deviceUuid;

  /// Nombre legible del equipo (`CAJA-1`).
  final String deviceName;

  /// Reloj inyectable: los tests de ventas y turnos necesitan viajar en el
  /// tiempo sin dormir.
  final DateTime Function()? clock;

  DateTime get now => (clock ?? DateTime.now)();

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (Migrator m) async {
          await m.createAll();
          Log.info('db', 'Esquema creado (v$schemaVersion)');
        },
        onUpgrade: (Migrator m, int from, int to) async {
          // -----------------------------------------------------------------
          // GUÍA DE MIGRACIÓN (obligatoria antes de tocar el esquema):
          //
          //   1. Subir `schemaVersion`.
          //   2. Añadir un caso `if (from < N)` con el cambio.
          //   3. Exportar el esquema en tests/golden: `dart run drift_dev
          //      schema dump` para verificar migraciones con `verifySelf`.
          //
          // Nunca se edita un caso de migración ya publicado: hay cajas en
          // producción con esa versión instalada.
          // -----------------------------------------------------------------
          Log.info('db', 'Migrando esquema de v$from a v$to');
          if (from < 1) {
            await m.createAll();
          }
        },
        beforeOpen: (OpeningDetails details) async {
          await customStatement('PRAGMA foreign_keys = ON;');
          if (details.wasCreated) {
            Log.info('db', 'Base de datos inicial creada');
          } else if (details.hadUpgrade) {
            Log.info('db', 'Base de datos actualizada a v$schemaVersion');
          }
        },
      );

  // ---------------------------------------------------------------------------
  // Outbox transaccional
  // ---------------------------------------------------------------------------

  /// Encola una operación para la nube. **Debe llamarse dentro de la misma
  /// transacción** que la escritura de negocio (ver [writeWithOutbox]).
  Future<void> enqueueOutbox({
    required SyncEntity entity,
    required String entityUuid,
    required SyncOperation operation,
    required Map<String, Object?> payload,
    DateTime? lwwTimestamp,
    int priority = 100,
    String? opId,
  }) async {
    final DateTime timestamp = now;
    await into(syncOutbox).insert(
      SyncOutboxCompanion.insert(
        opId: opId ?? IdGenerator.opId(),
        entity: entity,
        entityUuid: entityUuid,
        operation: operation,
        payloadJson: _encodePayload(payload),
        status: SyncStatus.pending,
        nextAttemptAt: timestamp,
        lwwTimestamp: lwwTimestamp ?? timestamp,
        priority: Value<int>(priority),
        deviceId: Value<String?>(deviceUuid),
        createdAt: timestamp,
        updatedAt: timestamp,
      ),
      // Sin `insertOrIgnore`: si alguna vez se repitiese un opId (uuid v4, no
      // debería ocurrir) queremos un fallo ruidoso que revierta la transacción,
      // nunca una operación perdida en silencio.
    );
  }

  /// Ejecuta una escritura de negocio y su encolado de sincronización en una
  /// **única transacción atómica**.
  ///
  /// Es el método que deben usar todos los servicios de dominio:
  /// o se guarda todo (venta + outbox), o no se guarda nada.
  Future<R> writeWithOutbox<R>({
    required Future<R> Function() action,
    SyncEntity? entity,
    String? entityUuid,
    SyncOperation operation = SyncOperation.insert,
    Map<String, Object?>? payload,
    DateTime? lwwTimestamp,
    int priority = 100,
  }) async {
    return transaction<R>(() async {
      final R result = await action();
      if (entity != null && entityUuid != null) {
        await enqueueOutbox(
          entity: entity,
          entityUuid: entityUuid,
          operation: operation,
          payload: payload ?? const <String, Object?>{},
          lwwTimestamp: lwwTimestamp,
          priority: priority,
        );
      }
      return result;
    });
  }

  /// Registra una entrada de auditoría (también encolada si aplica).
  Future<void> recordAudit({
    required String entity,
    required String action,
    String? entityUuid,
    String? userId,
    String? userName,
    Map<String, Object?>? before,
    Map<String, Object?>? after,
    String? note,
    bool enqueue = false,
  }) async {
    await into(auditLogs).insert(
      AuditLogsCompanion.insert(
        uuid: IdGenerator.uuid(),
        entity: entity,
        action: action,
        entityUuid: Value<String?>(entityUuid),
        userId: Value<String?>(userId),
        userName: Value<String?>(userName),
        beforeJson: Value<String?>(before == null ? null : _encodePayload(before)),
        afterJson: Value<String?>(after == null ? null : _encodePayload(after)),
        note: Value<String?>(note),
        createdAt: now,
      ),
    );
  }

  /// Serializa el payload de forma tolerante a tipos no soportados por JSON
  /// (Money, Quantity, DateTime, enums), evitando que un modelo nuevo en el
  /// dominio rompa la sincronización en producción.
  String _encodePayload(Map<String, Object?> payload) {
    return _jsonEncode(payload.map(
      (String key, Object? value) => MapEntry<String, Object?>(key, _normalize(value)),
    ));
  }

  Object? _normalize(Object? value) {
    switch (value) {
      case null:
        return null;
      case num():
      case bool():
      case String():
        return value;
      case DateTime():
        return value.toUtc().toIso8601String();
      case StorageKeyed():
        return value.storageKey;
      case Money():
        // Importante: los valores monetarios viajan como **centavos enteros**.
        // Serializar el objeto (por ejemplo con toString) rompería la
        // conciliación contable en la nube de forma silenciosa.
        return value.cents;
      case Quantity():
        return value.milli;
      case Map():
        return value.map((Object? k, Object? v) => MapEntry<String, Object?>('$k', _normalize(v)));
      case Iterable():
        return value.map(_normalize).toList(growable: false);
      default:
        return '$value';
    }
  }

  static String _jsonEncode(Map<String, Object?> value) {
    // Codificador JSON propio para no depender de dart:convert en el hot path
    // de la venta (evita asignaciones innecesarias) y para poder controlar el
    // orden de las claves (facilita diffs del outbox en soporte técnico).
    final StringBuffer buffer = StringBuffer('{');
    bool first = true;
    for (final MapEntry<String, Object?> entry in value.entries) {
      if (!first) buffer.write(',');
      first = false;
      buffer
        ..write(_jsonString(entry.key))
        ..write(':')
        ..write(_jsonValue(entry.value));
    }
    buffer.write('}');
    return buffer.toString();
  }

  static String _jsonValue(Object? value) {
    if (value == null) return 'null';
    if (value is bool) return value ? 'true' : 'false';
    if (value is num) return value.toString();
    if (value is String) return _jsonString(value);
    if (value is List) {
      return '[${value.map(_jsonValue).join(',')}]';
    }
    if (value is Map) {
      return _jsonEncode(value.map(
        (Object? k, Object? v) => MapEntry<String, Object?>('$k', v),
      ));
    }
    return _jsonString('$value');
  }

  static String _jsonString(String value) {
    final StringBuffer buffer = StringBuffer('"');
    for (final int rune in value.runes) {
      switch (rune) {
        case 0x22:
          buffer.write(r'\"');
        case 0x5C:
          buffer.write(r'\\');
        case 0x0A:
          buffer.write(r'\n');
        case 0x0D:
          buffer.write(r'\r');
        case 0x09:
          buffer.write(r'\t');
        default:
          if (rune < 0x20) {
            buffer.write('\\u${rune.toRadixString(16).padLeft(4, '0')}');
          } else {
            buffer.writeCharCode(rune);
          }
      }
    }
    buffer.write('"');
    return buffer.toString();
  }

  /// Contadores de la cola (barra de estado y panel de sincronización).
  Future<int> pendingOutboxCount() async {
    final Expression<bool> pendingFilter = syncOutbox.status.isInValues(
      <SyncStatus>[SyncStatus.pending, SyncStatus.retry, SyncStatus.inFlight],
    );
    final Expression<int> count = syncOutbox.opId.count();
    final TypedResult result = await (selectOnly(syncOutbox)
          ..addColumns(<Expression<Object>>[count])
          ..where(pendingFilter))
        .getSingle();
    return result.read(count) ?? 0;
  }

  /// Respaldo consistente del archivo (API de backup en caliente de SQLite).
  Future<void> backupTo(String targetPath) async {
    // VACUUM INTO no admite parámetros enlazados: se escapa la ruta.
    final String escaped = targetPath.replaceAll("'", "''");
    await customStatement("VACUUM INTO '$escaped';");
    Log.info('db', 'Respaldo generado', data: <String, Object?>{'path': targetPath});
  }

  /// Compactación y limpieza de WAL. Se ejecuta al cerrar el día.
  Future<void> compact() async {
    await customStatement('PRAGMA wal_checkpoint(TRUNCATE);');
    await customStatement('VACUUM;');
    await customStatement('PRAGMA optimize;');
  }

  /// Purga de la cola ya sincronizada (retención configurable).
  Future<int> purgeSyncedOutbox({Duration retention = const Duration(days: 15)}) async {
    final DateTime threshold = now.subtract(retention);
    final int removed = await (delete(syncOutbox)
          ..where((t) =>
              t.status.isInValues(<SyncStatus>[SyncStatus.synced, SyncStatus.conflict]) &
              t.syncedAt.isSmallerThanValue(threshold)))
        .go();
    if (removed > 0) {
      Log.debug('db', 'Outbox purgado', data: <String, Object?>{'filas': removed});
    }
    return removed;
  }

  /// Verificación de integridad solicitada desde Configuración > Mantenimiento.
  Future<String> integrityCheck() async {
    final QueryRow row = await customSelect('PRAGMA integrity_check;').getSingle();
    return row.data.values.first?.toString() ?? 'desconocido';
  }

  /// Cierra la base de datos de forma ordenada (checkpoint final del WAL).
  Future<void> closeGracefully() async {
    try {
      await customStatement('PRAGMA wal_checkpoint(TRUNCATE);');
    } on Object catch (error) {
      Log.warning('db', 'No se pudo hacer checkpoint al cerrar', error: error);
    }
    await close();
  }

  /// Descripción legible de la configuración activa (panel de diagnóstico).
  Map<String, Object?> describeEnvironment() => <String, Object?>{
        'schema_version': schemaVersion,
        'device_uuid': deviceUuid,
        'device_name': deviceName,
        'app_version': AppConfig.appVersion,
        'environment': AppConfig.environment.name,
        'encryption': AppConfig.databaseEncryptionEnabled,
      };
}
