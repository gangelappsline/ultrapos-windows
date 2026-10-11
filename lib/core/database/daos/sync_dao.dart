import 'package:drift/drift.dart';

import '../../domain/enums.dart';
import '../../sync/sync_models.dart';
import '../../utils/id_generator.dart';
import '../app_database.dart';
import '../tables/sync_tables.dart';

part 'sync_dao.g.dart';

/// Estadísticas de la cola de sincronización (barra de estado y panel).
class SyncQueueStats {
  const SyncQueueStats({
    required this.pending,
    required this.retrying,
    required this.inFlight,
    required this.failed,
    required this.syncedToday,
    this.oldestPendingAt,
    this.lastSyncedAt,
  });

  static const SyncQueueStats empty = SyncQueueStats(
    pending: 0,
    retrying: 0,
    inFlight: 0,
    failed: 0,
    syncedToday: 0,
  );

  final int pending;
  final int retrying;
  final int inFlight;
  final int failed;
  final int syncedToday;
  final DateTime? oldestPendingAt;
  final DateTime? lastSyncedAt;

  /// Operaciones que aún no han llegado a la nube.
  int get outstanding => pending + retrying + inFlight;

  bool get isHealthy => failed == 0;

  /// Antigüedad del registro más antiguo sin sincronizar (alerta de soporte).
  Duration get oldestAge => oldestPendingAt == null
      ? Duration.zero
      : DateTime.now().toUtc().difference(oldestPendingAt!);

  @override
  String toString() => 'SyncQueueStats(pendientes: $outstanding, fallidos: $failed)';

  SyncQueueStats copyWith({
    int? pending,
    int? retrying,
    int? inFlight,
    int? failed,
    int? syncedToday,
    DateTime? oldestPendingAt,
    DateTime? lastSyncedAt,
  }) =>
      SyncQueueStats(
        pending: pending ?? this.pending,
        retrying: retrying ?? this.retrying,
        inFlight: inFlight ?? this.inFlight,
        failed: failed ?? this.failed,
        syncedToday: syncedToday ?? this.syncedToday,
        oldestPendingAt: oldestPendingAt ?? this.oldestPendingAt,
        lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      );
}

/// Acceso a la cola de sincronización (outbox), cursores y bitácora.
@DriftAccessor(tables: <Type>[SyncOutbox, SyncCursors, SyncEvents])
class SyncDao extends DatabaseAccessor<AppDatabase> with _$SyncDaoMixin {
  SyncDao(AppDatabase db) : super(db);

  static const Duration _staleInFlightThreshold = Duration(minutes: 5);

  // ---------------------------------------------------------------------------
  // Lectura de la cola
  // ---------------------------------------------------------------------------

  /// Operaciones listas para enviar, ordenadas por prioridad y antigüedad.
  Future<List<SyncQueueEntry>> dueEntries({int limit = 40}) {
    final DateTime now = attachedDatabase.now;
    return (select(syncOutbox)
          ..where((t) =>
              t.status.isInValues(<SyncStatus>[SyncStatus.pending, SyncStatus.retry]) &
              t.nextAttemptAt.isSmallerOrEqualValue(now))
          ..orderBy(<OrderingTerm Function($SyncOutboxTable)>[
            (t) => OrderingTerm(expression: t.priority),
            (t) => OrderingTerm(expression: t.createdAt),
          ])
          ..limit(limit))
        .get();
  }

  Future<List<SyncQueueEntry>> failedEntries({int limit = 200}) => (select(syncOutbox)
        ..where((t) => t.status.equalsValue(SyncStatus.failed))
        ..orderBy(<OrderingTerm Function($SyncOutboxTable)>[
          (t) => OrderingTerm(expression: t.updatedAt, mode: OrderingMode.desc),
        ])
        ..limit(limit))
      .get();

  Future<SyncQueueEntry?> findByOpId(String opId) =>
      (select(syncOutbox)..where((t) => t.opId.equals(opId))).getSingleOrNull();

  /// Cola pendiente visible en el panel de sincronización.
  Stream<List<SyncQueueEntry>> watchQueue({int limit = 200}) => (select(syncOutbox)
        ..where((t) => t.status.isNotInValues(<SyncStatus>[SyncStatus.synced]))
        ..orderBy(<OrderingTerm Function($SyncOutboxTable)>[
          (t) => OrderingTerm(expression: t.priority),
          (t) => OrderingTerm(expression: t.createdAt),
        ])
        ..limit(limit))
      .watch();

  Stream<int> watchPendingCount() {
    final Expression<int> count = syncOutbox.opId.count();
    return (selectOnly(syncOutbox)
          ..addColumns(<Expression<Object>>[count])
          ..where(syncOutbox.status.isInValues(<SyncStatus>[
            SyncStatus.pending,
            SyncStatus.retry,
            SyncStatus.inFlight,
          ])))
        .watchSingle()
        .map((TypedResult row) => row.read(count) ?? 0);
  }

  Future<int> pendingCount() async {
    final QueryRow row = await customSelect(
      '''
      SELECT COUNT(*) AS total
        FROM sync_outbox
       WHERE status IN ('pending', 'retry', 'in_flight');
      ''',
    ).getSingle();
    return row.read<int>('total');
  }

  /// Estadísticas completas para la UI.
  Future<SyncQueueStats> stats() async {
    final QueryRow row = await customSelect(
      '''
      SELECT
        COALESCE(SUM(CASE WHEN status = 'pending'   THEN 1 ELSE 0 END), 0) AS pending,
        COALESCE(SUM(CASE WHEN status = 'retry'     THEN 1 ELSE 0 END), 0) AS retrying,
        COALESCE(SUM(CASE WHEN status = 'in_flight' THEN 1 ELSE 0 END), 0) AS in_flight,
        COALESCE(SUM(CASE WHEN status = 'failed'    THEN 1 ELSE 0 END), 0) AS failed,
        COALESCE(SUM(CASE WHEN status IN ('synced','conflict')
                           AND synced_at >= ? THEN 1 ELSE 0 END), 0)       AS synced_today,
        MIN(CASE WHEN status IN ('pending','retry','in_flight')
                 THEN created_at END)                                      AS oldest_pending,
        MAX(synced_at)                                                     AS last_synced
        FROM sync_outbox;
      ''',
      variables: <Variable<Object>>[
        Variable.withInt(
          DateTime.now().toUtc().subtract(const Duration(days: 1)).millisecondsSinceEpoch,
        ),
      ],
    ).getSingle();

    int? readOptional(String column) => row.readNullable<int>(column);

    return SyncQueueStats(
      pending: row.read<int>('pending'),
      retrying: row.read<int>('retrying'),
      inFlight: row.read<int>('in_flight'),
      failed: row.read<int>('failed'),
      syncedToday: row.read<int>('synced_today'),
      oldestPendingAt: readOptional('oldest_pending') == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(readOptional('oldest_pending')!, isUtc: true),
      lastSyncedAt: readOptional('last_synced') == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(readOptional('last_synced')!, isUtc: true),
    );
  }

  /// Entidades con cambios pendientes (para mostrar en el panel).
  Future<Map<SyncEntity, int>> pendingByEntity() async {
    final List<QueryRow> rows = await customSelect(
      '''
      SELECT entity, COUNT(*) AS total
        FROM sync_outbox
       WHERE status IN ('pending', 'retry', 'in_flight', 'failed')
       GROUP BY entity;
      ''',
    ).get();
    return <SyncEntity, int>{
      for (final QueryRow row in rows)
        SyncEntity.tryFromStorage(row.read<String>('entity')) ?? SyncEntity.setting:
            row.read<int>('total'),
    };
  }

  // ---------------------------------------------------------------------------
  // Transiciones de estado
  // ---------------------------------------------------------------------------

  /// Marca las operaciones como "en vuelo" y devuelve cuántas se marcaron.
  ///
  /// Evita el doble envío si la aplicación se cierra a mitad del envío. Si el
  /// proceso muere, [recoverStaleInFlight] las devuelve a la cola.
  Future<int> markInFlight(List<String> opIds) async {
    if (opIds.isEmpty) return 0;
    final DateTime now = attachedDatabase.now;
    return (update(syncOutbox)..where((t) => t.opId.isIn(opIds))).write(
      SyncOutboxCompanion(
        status: const Value<SyncStatus>(SyncStatus.inFlight),
        lastAttemptAt: Value<DateTime?>(now),
        updatedAt: Value<DateTime>(now),
      ),
    );
  }

  Future<int> markSynced(List<String> opIds, {SyncStatus status = SyncStatus.synced}) async {
    if (opIds.isEmpty) return 0;
    final DateTime now = attachedDatabase.now;
    return (update(syncOutbox)..where((t) => t.opId.isIn(opIds))).write(
      SyncOutboxCompanion(
        status: Value<SyncStatus>(status),
        syncedAt: Value<DateTime?>(now),
        lastError: const Value<String?>(null),
        updatedAt: Value<DateTime>(now),
      ),
    );
  }

  /// Programa un reintento con retroceso exponencial.
  Future<void> markRetry({
    required String opId,
    required int attempts,
    required Duration nextDelay,
    String? error,
    int httpStatus = 0,
  }) async {
    final DateTime now = attachedDatabase.now;
    await (update(syncOutbox)..where((t) => t.opId.equals(opId))).write(
      SyncOutboxCompanion(
        status: const Value<SyncStatus>(SyncStatus.retry),
        attempts: Value<int>(attempts),
        nextAttemptAt: Value<DateTime>(now.add(nextDelay)),
        lastError: Value<String?>(_truncate(error)),
        lastHttpStatus: Value<int>(httpStatus),
        lastAttemptAt: Value<DateTime?>(now),
        updatedAt: Value<DateTime>(now),
      ),
    );
  }

  /// Marca la operación como fallida de forma definitiva (requiere soporte).
  Future<void> markFailed({
    required String opId,
    required int attempts,
    required String error,
    int httpStatus = 0,
  }) async {
    final DateTime now = attachedDatabase.now;
    await (update(syncOutbox)..where((t) => t.opId.equals(opId))).write(
      SyncOutboxCompanion(
        status: const Value<SyncStatus>(SyncStatus.failed),
        attempts: Value<int>(attempts),
        lastError: Value<String?>(_truncate(error)),
        lastHttpStatus: Value<int>(httpStatus),
        lastAttemptAt: Value<DateTime?>(now),
        updatedAt: Value<DateTime>(now),
      ),
    );
  }

  /// Registra que el servidor ganó el conflicto (LWW a favor del remoto).
  Future<void> markResolvedByRemote({
    required String opId,
    required String detail,
  }) async {
    final DateTime now = attachedDatabase.now;
    await (update(syncOutbox)..where((t) => t.opId.equals(opId))).write(
      SyncOutboxCompanion(
        status: const Value<SyncStatus>(SyncStatus.conflict),
        lastError: Value<String?>(_truncate(detail)),
        syncedAt: Value<DateTime?>(now),
        updatedAt: Value<DateTime>(now),
      ),
    );
  }

  /// Devuelve a la cola las operaciones atascadas en "en vuelo".
  Future<int> recoverStaleInFlight() async {
    final DateTime threshold = attachedDatabase.now.subtract(_staleInFlightThreshold);
    return (update(syncOutbox)
          ..where((t) =>
              t.status.equalsValue(SyncStatus.inFlight) &
              t.lastAttemptAt.isSmallerThanValue(threshold)))
        .write(
      SyncOutboxCompanion(
        status: const Value<SyncStatus>(SyncStatus.pending),
        lastError: const Value<String?>('Reintentado tras interrupción del envío'),
        updatedAt: Value<DateTime>(attachedDatabase.now),
      ),
    );
  }

  /// Reintenta manualmente una operación fallida (botón del panel).
  Future<void> retryEntry(String opId) async {
    final DateTime now = attachedDatabase.now;
    await (update(syncOutbox)..where((t) => t.opId.equals(opId))).write(
      SyncOutboxCompanion(
        status: const Value<SyncStatus>(SyncStatus.pending),
        nextAttemptAt: Value<DateTime>(now),
        attempts: const Value<int>(0),
        updatedAt: Value<DateTime>(now),
      ),
    );
  }

  Future<void> retryAllFailed() async {
    final DateTime now = attachedDatabase.now;
    await (update(syncOutbox)..where((t) => t.status.equalsValue(SyncStatus.failed)))
        .write(
      SyncOutboxCompanion(
        status: const Value<SyncStatus>(SyncStatus.pending),
        nextAttemptAt: Value<DateTime>(now),
        attempts: const Value<int>(0),
        updatedAt: Value<DateTime>(now),
      ),
    );
  }

  /// Descarta una operación (con registro en la bitácora: nunca en silencio).
  Future<void> discardEntry(String opId, {String? reason}) async {
    final SyncQueueEntry? entry = await findByOpId(opId);
    if (entry == null) return;
    await transaction(() async {
      await (delete(syncOutbox)..where((t) => t.opId.equals(opId))).go();
      await logEvent(
        level: 'warning',
        message: 'Operación descartada manualmente: ${entry.entity.storageKey} '
            '(${entry.entityUuid})',
        entity: entry.entity,
        entityUuid: entry.entityUuid,
        metrics: <String, Object?>{'op_id': opId, 'reason': reason},
      );
    });
  }

  /// Reencola **todo** el histórico (recuperación tras un cambio de backend).
  Future<int> requeueAll({bool onlyFailed = false}) async {
    final DateTime now = attachedDatabase.now;
    return (update(syncOutbox)
          ..where((t) => onlyFailed
              ? t.status.equalsValue(SyncStatus.failed)
              : t.status.isNotInValues(<SyncStatus>[SyncStatus.pending, SyncStatus.inFlight])))
        .write(
      SyncOutboxCompanion(
        status: const Value<SyncStatus>(SyncStatus.pending),
        attempts: const Value<int>(0),
        nextAttemptAt: Value<DateTime>(now),
        updatedAt: Value<DateTime>(now),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Cursores de lectura
  // ---------------------------------------------------------------------------

  Future<SyncCursor?> cursorFor(SyncEntity entity) =>
      (select(syncCursors)..where((t) => t.entity.equalsValue(entity))).getSingleOrNull();

  Future<void> saveCursor({
    required SyncEntity entity,
    required DateTime lastPulledAt,
    int rowsApplied = 0,
    int serverVersion = 1,
  }) async {
    final DateTime now = attachedDatabase.now;
    await into(syncCursors).insertOnConflictUpdate(
      SyncCursorsCompanion.insert(
        entity: entity,
        lastPulledAt: lastPulledAt,
        lastServerVersion: Value<int>(serverVersion),
        rowsApplied: Value<int>(rowsApplied),
        updatedAt: now,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Bitácora de sincronización
  // ---------------------------------------------------------------------------

  Future<void> logEvent({
    required String level,
    required String message,
    SyncEntity? entity,
    String? entityUuid,
    Map<String, Object?> metrics = const <String, Object?>{},
  }) async {
    final DateTime now = attachedDatabase.now;
    await into(syncEvents).insert(
      SyncEventsCompanion.insert(
        uuid: IdGenerator.uuid(),
        level: Value<String>(level),
        message: message,
        entity: Value<SyncEntity?>(entity),
        entityUuid: Value<String?>(entityUuid),
        metricsJson: Value<String?>(metrics.isEmpty ? null : _metricsToJson(metrics)),
        createdAt: now,
      ),
    );
  }

  Stream<List<SyncEvent>> watchEvents({int limit = 60}) => (select(syncEvents)
        ..orderBy(<OrderingTerm Function($SyncEventsTable)>[
          (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
        ])
        ..limit(limit))
      .watch();

  Future<void> purgeEvents({Duration retention = const Duration(days: 30)}) async {
    final DateTime threshold = attachedDatabase.now.subtract(retention);
    await (delete(syncEvents)..where((t) => t.createdAt.isSmallerThanValue(threshold))).go();
  }

  /// Limpieza periódica: cola ya sincronizada y bitácora antigua.
  Future<void> housekeeping() async {
    await attachedDatabase.purgeSyncedOutbox();
    await purgeEvents();
  }

  String _truncate(String? value, {int max = 480}) {
    if (value == null) return '';
    return value.length <= max ? value : '${value.substring(0, max)}…';
  }

  String _metricsToJson(Map<String, Object?> metrics) {
    final StringBuffer buffer = StringBuffer('{');
    bool first = true;
    for (final MapEntry<String, Object?> entry in metrics.entries) {
      if (!first) buffer.write(',');
      first = false;
      buffer.write('"${entry.key}":${_jsonPrimitive(entry.value)}');
    }
    buffer.write('}');
    return buffer.toString();
  }

  String _jsonPrimitive(Object? value) {
    if (value == null) return 'null';
    if (value is num || value is bool) return '$value';
    final String escaped = '$value'.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
    return '"$escaped"';
  }
}
