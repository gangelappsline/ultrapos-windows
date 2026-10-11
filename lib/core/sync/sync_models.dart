import 'package:flutter/foundation.dart';

import '../domain/enums.dart';

/// Modelos del motor de sincronización.
///
/// Todos son **serializables a JSON plano** porque cruzan la frontera del
/// isolate de red: nada de objetos de Drift, ni de Riverpod, ni recursos
/// nativos en esta capa.
library;

/// Estado de conectividad del equipo.
enum NetworkState {
  online('En línea'),
  offline('Sin conexión'),
  unknown('Verificando');

  const NetworkState(this.label);

  final String label;

  bool get isOnline => this == NetworkState.online;
}

/// Operación lista para enviar (vista serializable de una fila del outbox).
@immutable
class SyncOperationEnvelope {
  const SyncOperationEnvelope({
    required this.opId,
    required this.entity,
    required this.entityUuid,
    required this.operation,
    required this.payload,
    required this.lwwTimestamp,
    required this.deviceId,
    this.attempt = 0,
    this.syncVersion = 1,
  });

  /// Idempotency key: el servidor la registra para no aplicar dos veces.
  final String opId;
  final SyncEntity entity;
  final String entityUuid;
  final SyncOperation operation;
  final Map<String, Object?> payload;

  /// Marca de tiempo de la última escritura local (Last Write Wins).
  final DateTime lwwTimestamp;
  final String deviceId;
  final int attempt;
  final int syncVersion;

  Map<String, Object?> toJson() => <String, Object?>{
        'op_id': opId,
        'entity': entity.storageKey,
        'entity_id': entityUuid,
        'op': operation.storageKey,
        'payload': payload,
        'lww_ts': lwwTimestamp.toUtc().toIso8601String(),
        'device_id': deviceId,
        'attempt': attempt,
        'sync_version': syncVersion,
      };

  factory SyncOperationEnvelope.fromJson(Map<String, Object?> json) => SyncOperationEnvelope(
        opId: '${json['op_id']}',
        entity: SyncEntity.tryFromStorage('${json['entity']}') ?? SyncEntity.setting,
        entityUuid: '${json['entity_id']}',
        operation: SyncOperation.fromStorage('${json['op']}'),
        payload: (json['payload'] as Map<Object?, Object?>? ?? <Object?, Object?>{})
            .map((Object? k, Object? v) => MapEntry<String, Object?>('$k', v)),
        lwwTimestamp:
            DateTime.tryParse('${json['lww_ts']}')?.toUtc() ?? DateTime.now().toUtc(),
        deviceId: '${json['device_id']}',
        attempt: int.tryParse('${json['attempt']}') ?? 0,
        syncVersion: int.tryParse('${json['sync_version']}') ?? 1,
      );
}

/// Resultado que el servidor devuelve por cada operación aplicada.
@immutable
class RemoteOperationResult {
  const RemoteOperationResult({
    required this.opId,
    required this.status,
    this.message,
    this.serverUpdatedAt,
    this.conflict = false,
  });

  /// El servidor confirmó la aplicación (idempotente: repetirlo es inocuo).
  static const String statusApplied = 'applied';

  /// El servidor ya tenía esta operación (reintento tras timeout): éxito igual.
  static const String statusDuplicate = 'duplicate';

  /// El servidor rechazó la operación de forma permanente.
  static const String statusRejected = 'rejected';

  /// Conflicto temporal: el remoto tiene una versión más nueva (LWW remoto).
  static const String statusConflict = 'conflict';

  /// Fallo transitorio en el servidor: reintentar con retroceso.
  static const String statusRetry = 'retry';

  final String opId;
  final String status;
  final String? message;
  final DateTime? serverUpdatedAt;

  /// `true` cuando el LWW favoreció a la nube y hay que recargar la fila local.
  final bool conflict;

  bool get isSuccess => status == statusApplied || status == statusDuplicate;

  factory RemoteOperationResult.fromJson(Map<String, Object?> json) => RemoteOperationResult(
        opId: '${json['op_id']}',
        status: '${json['status'] ?? statusApplied}',
        message: json['message'] == null ? null : '${json['message']}',
        serverUpdatedAt: json['server_updated_at'] == null
            ? null
            : DateTime.tryParse('${json['server_updated_at']}')?.toUtc(),
        conflict: json['conflict'] == true,
      );
}

/// Cambio remoto a aplicar localmente (pull del catálogo maestro).
@immutable
class RemoteChange {
  const RemoteChange({
    required this.entity,
    required this.entityUuid,
    required this.operation,
    required this.payload,
    required this.updatedAt,
    this.serverVersion = 1,
  });

  final SyncEntity entity;
  final String entityUuid;
  final SyncOperation operation;
  final Map<String, Object?> payload;
  final DateTime updatedAt;
  final int serverVersion;

  factory RemoteChange.fromJson(Map<String, Object?> json) => RemoteChange(
        entity: SyncEntity.tryFromStorage('${json['entity']}') ?? SyncEntity.setting,
        entityUuid: '${json['entity_id']}',
        operation: SyncOperation.fromStorage('${json['op']}'),
        payload: (json['payload'] as Map<Object?, Object?>? ?? <Object?, Object?>{})
            .map((Object? k, Object? v) => MapEntry<String, Object?>('$k', v)),
        updatedAt: DateTime.tryParse('${json['updated_at']}')?.toUtc() ?? DateTime.now().toUtc(),
        serverVersion: int.tryParse('${json['sync_version']}') ?? 1,
      );
}

/// Resultado completo de un ciclo de sincronización.
@immutable
class SyncCycleReport {
  const SyncCycleReport({
    required this.startedAt,
    required this.finishedAt,
    required this.pushed,
    required this.pulled,
    required this.conflicts,
    required this.retried,
    required this.failed,
    this.skippedReason,
    this.errorMessage,
  });

  factory SyncCycleReport.offline(DateTime at) => SyncCycleReport(
        startedAt: at,
        finishedAt: at,
        pushed: 0,
        pulled: 0,
        conflicts: 0,
        retried: 0,
        failed: 0,
        skippedReason: 'Sin conexión',
      );

  factory SyncCycleReport.disabled(DateTime at) => SyncCycleReport(
        startedAt: at,
        finishedAt: at,
        pushed: 0,
        pulled: 0,
        conflicts: 0,
        retried: 0,
        failed: 0,
        skippedReason: 'Sincronización desactivada',
      );

  final DateTime startedAt;
  final DateTime finishedAt;

  /// Operaciones confirmadas por la nube.
  final int pushed;

  /// Registros aplicados desde la nube.
  final int pulled;

  /// Conflictos resueltos (LWW).
  final int conflicts;

  /// Operaciones reprogramadas para reintento.
  final int retried;

  /// Operaciones que agotaron los reintentos.
  final int failed;

  /// Motivo por el que el ciclo no hizo nada (offline, desactivado...).
  final String? skippedReason;

  final String? errorMessage;

  Duration get duration => finishedAt.difference(startedAt);

  bool get didWork => pushed > 0 || pulled > 0;

  bool get hasProblems => failed > 0 || errorMessage != null;

  Map<String, Object?> toMetrics() => <String, Object?>{
        'pushed': pushed,
        'pulled': pulled,
        'conflicts': conflicts,
        'retried': retried,
        'failed': failed,
        'duration_ms': duration.inMilliseconds,
        if (skippedReason != null) 'skipped': skippedReason,
        if (errorMessage != null) 'error': errorMessage,
      };

  @override
  String toString() => 'SyncCycleReport(pushed: $pushed, pulled: $pulled, '
      'conflicts: $conflicts, retried: $retried, failed: $failed, '
      'en ${duration.inMilliseconds} ms)';
}

/// Fotografía del estado de sincronización que consume la interfaz.
@immutable
class SyncStatusSnapshot {
  const SyncStatusSnapshot({
    required this.network,
    required this.isSyncing,
    required this.pendingCount,
    required this.failedCount,
    this.lastSyncAt,
    this.lastError,
    this.currentBatchTotal = 0,
    this.currentBatchSent = 0,
  });

  static const SyncStatusSnapshot idle = SyncStatusSnapshot(
    network: NetworkState.unknown,
    isSyncing: false,
    pendingCount: 0,
    failedCount: 0,
  );

  final NetworkState network;
  final bool isSyncing;
  final int pendingCount;
  final int failedCount;
  final DateTime? lastSyncAt;
  final String? lastError;

  /// Progreso del lote en curso (para una barra de progreso honesta).
  final int currentBatchTotal;
  final int currentBatchSent;

  bool get isOnline => network.isOnline;
  bool get hasPending => pendingCount > 0;
  bool get needsAttention => failedCount > 0;

  double get progress =>
      currentBatchTotal == 0 ? 0 : (currentBatchSent / currentBatchTotal).clamp(0, 1);

  /// Texto corto para la barra de estado inferior.
  String get label {
    if (isSyncing) return 'Sincronizando…';
    if (!isOnline) {
      return pendingCount > 0 ? 'Sin conexión · $pendingCount pendientes' : 'Sin conexión';
    }
    if (failedCount > 0) return '$failedCount con error';
    if (pendingCount > 0) return '$pendingCount pendientes';
    return 'Sincronizado';
  }

  SyncStatusSnapshot copyWith({
    NetworkState? network,
    bool? isSyncing,
    int? pendingCount,
    int? failedCount,
    DateTime? lastSyncAt,
    String? lastError,
    bool clearError = false,
    int? currentBatchTotal,
    int? currentBatchSent,
  }) =>
      SyncStatusSnapshot(
        network: network ?? this.network,
        isSyncing: isSyncing ?? this.isSyncing,
        pendingCount: pendingCount ?? this.pendingCount,
        failedCount: failedCount ?? this.failedCount,
        lastSyncAt: lastSyncAt ?? this.lastSyncAt,
        lastError: clearError ? null : (lastError ?? this.lastError),
        currentBatchTotal: currentBatchTotal ?? this.currentBatchTotal,
        currentBatchSent: currentBatchSent ?? this.currentBatchSent,
      );
}

/// Respuesta del endpoint de empuje (`/sync/push`).
@immutable
class PushResponse {
  const PushResponse({
    required this.results,
    this.serverTime,
    this.pullCursor,
  });

  final List<RemoteOperationResult> results;
  final DateTime? serverTime;

  /// Marca de tiempo del servidor a usar como cursor de lectura.
  final DateTime? pullCursor;

  factory PushResponse.fromJson(Map<String, Object?> json) {
    final List<Object?> raw = json['results'] as List<Object?>? ?? <Object?>[];
    return PushResponse(
      results: raw
          .whereType<Map<Object?, Object?>>()
          .map((Map<Object?, Object?> item) => RemoteOperationResult.fromJson(
                item.map((Object? k, Object? v) => MapEntry<String, Object?>('$k', v)),
              ))
          .toList(growable: false),
      serverTime: DateTime.tryParse('${json['server_time']}')?.toUtc(),
      pullCursor: DateTime.tryParse('${json['pull_cursor']}')?.toUtc(),
    );
  }
}

/// Respuesta del endpoint de lectura (`/sync/pull`).
@immutable
class PullResponse {
  const PullResponse({required this.changes, this.cursor});

  final List<RemoteChange> changes;
  final DateTime? cursor;

  factory PullResponse.fromJson(Map<String, Object?> json) {
    final List<Object?> raw = json['changes'] as List<Object?>? ?? <Object?>[];
    return PullResponse(
      changes: raw
          .whereType<Map<Object?, Object?>>()
          .map((Map<Object?, Object?> item) => RemoteChange.fromJson(
                item.map((Object? k, Object? v) => MapEntry<String, Object?>('$k', v)),
              ))
          .toList(growable: false),
      cursor: DateTime.tryParse('${json['cursor']}')?.toUtc(),
    );
  }
}

/// Configuración de transporte (inmutable y **serializable**, para poder
/// enviarse al isolate de red).
@immutable
class RemoteConfig {
  const RemoteConfig({
    required this.baseUrl,
    required this.deviceId,
    this.apiKey = '',
    this.timeoutSeconds = 25,
    this.mode = RemoteMode.rest,
  });

  final String baseUrl;

  /// Clave pública / token de API. En producción se recomienda un token
  /// rotable por dispositivo en lugar de incrustar credenciales maestras.
  final String apiKey;
  final String deviceId;
  final int timeoutSeconds;
  final RemoteMode mode;

  bool get isConfigured => baseUrl.trim().isNotEmpty;

  Map<String, Object?> toJson() => <String, Object?>{
        'base_url': baseUrl,
        'api_key': apiKey,
        'device_id': deviceId,
        'timeout_seconds': timeoutSeconds,
        'mode': mode.name,
      };
}

/// Backend de destino.
enum RemoteMode {
  /// API REST propia (`POST /sync/push`, `POST /sync/pull`).
  rest,

  /// Supabase (PostgREST + RPC `apply_sync_batch`).
  supabase,

  /// Modo demo: simula la nube en memoria. Permite probar el motor completo
  /// sin backend (y es lo que se usa en tests).
  mock,
}
