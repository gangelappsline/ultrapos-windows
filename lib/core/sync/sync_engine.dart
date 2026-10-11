import 'dart:convert';

import '../config/app_config.dart';
import '../database/app_database.dart';
import '../domain/enums.dart';
import '../logging/app_logger.dart';
import 'remote_api.dart';
import 'remote_apply.dart';
import 'sync_backoff.dart';
import 'sync_models.dart';

/// Motor de sincronización: la pieza que decide **qué** se envía, **cuándo** y
/// **qué pasa cuando falla**.
///
/// Un ciclo ([runCycle]) hace, en este orden exacto:
///
///   1. Recupera operaciones que quedaron "en vuelo" por un cierre abrupto.
///   2. **Empuja** lotes de operaciones pendientes (máx. `syncBatchSize`).
///   3. Marca como sincronizadas las confirmadas por el servidor.
///   4. Reprograma con retroceso exponencial las que fallaron.
///   5. **Descarga** cambios de datos maestros y los aplica con LWW.
///   6. Registra el ciclo en la bitácora y limpia cola antigua.
///
/// El motor no conoce la UI ni la conectividad: recibe ese dato desde
/// `SyncService`, lo que lo hace **totalmente testeable** con `MockRemoteApi`.
class SyncEngine {
  SyncEngine({
    required this.database,
    required this.remote,
    BackoffPolicy? backoff,
    this.onProgress,
  }) : backoff = backoff ?? BackoffPolicy.standard;

  final AppDatabase database;
  final RemoteSyncApi remote;
  final BackoffPolicy backoff;

  /// Notificación de progreso del lote en curso (barra de la barra de estado).
  final void Function(int sent, int total)? onProgress;

  static const String _scope = 'sync_engine';

  /// Ejecuta un ciclo completo. **Nunca lanza excepciones**: devuelve un
  /// informe. Un motor de sincronización que propaga errores a la UI termina
  /// bloqueando el cobro por un problema de red, y eso es inaceptable.
  Future<SyncCycleReport> runCycle({
    required bool isOnline,
    bool pullEnabled = true,
  }) async {
    final DateTime startedAt = DateTime.now().toUtc();

    if (!remote.isConfigured) {
      return SyncCycleReport.disabled(startedAt);
    }
    if (!isOnline) {
      // Se registra en modo DEBUG: si no, una caja sin internet llenaría el
      // archivo de log con un evento cada 30 segundos.
      Log.debug(_scope, 'Ciclo omitido: sin conexión');
      return SyncCycleReport.offline(startedAt);
    }

    int pushed = 0;
    int pulled = 0;
    int conflicts = 0;
    int retried = 0;
    int failed = 0;
    String? errorMessage;

    try {
      await database.syncDao.recoverStaleInFlight();

      // ---------------------------------------------------------------------
      // PUSH
      // ---------------------------------------------------------------------
      for (int batchIndex = 0; batchIndex < AppConfig.syncMaxBatchesPerCycle; batchIndex++) {
        final List<SyncQueueEntry> entries =
            await database.syncDao.dueEntries(limit: AppConfig.syncBatchSize);
        if (entries.isEmpty) break;

        final List<String> opIds = entries.map((SyncQueueEntry e) => e.opId).toList(growable: false);
        await database.syncDao.markInFlight(opIds);

        final List<SyncOperationEnvelope> envelopes = entries
            .map((SyncQueueEntry entry) => SyncOperationEnvelope(
                  opId: entry.opId,
                  entity: entry.entity,
                  entityUuid: entry.entityUuid,
                  operation: entry.operation,
                  payload: _decodePayload(entry.payloadJson),
                  lwwTimestamp: entry.lwwTimestamp,
                  deviceId: entry.deviceId ?? database.deviceUuid,
                  attempt: entry.attempts + 1,
                  syncVersion: 1,
                ))
            .toList(growable: false);

        onProgress?.call(0, envelopes.length);

        final PushOutcome outcome = await _pushBatch(envelopes);
        pushed += outcome.applied;
        conflicts += outcome.conflicts;
        retried += outcome.retried;
        failed += outcome.failed;
        onProgress?.call(envelopes.length, envelopes.length);

        // Si el lote completo falló por red, no tiene sentido seguir intentando
        // en este ciclo: el servidor no está disponible.
        if (outcome.transportFailure) {
          errorMessage = outcome.errorMessage;
          break;
        }
      }

      // ---------------------------------------------------------------------
      // PULL (solo datos maestros)
      // ---------------------------------------------------------------------
      if (pullEnabled && errorMessage == null) {
        pulled = await _pullChanges();
      }
    } on Object catch (error, stack) {
      errorMessage = error.toString();
      Log.error(_scope, 'Ciclo de sincronización fallido', error: error, stackTrace: stack);
    }

    final SyncCycleReport report = SyncCycleReport(
      startedAt: startedAt,
      finishedAt: DateTime.now().toUtc(),
      pushed: pushed,
      pulled: pulled,
      conflicts: conflicts,
      retried: retried,
      failed: failed,
      errorMessage: errorMessage,
    );

    // Bitácora: solo se registra lo relevante (un ciclo vacío no ensucia el log).
    if (report.didWork || report.hasProblems) {
      await database.syncDao.logEvent(
        level: report.hasProblems ? 'error' : 'success',
        message: report.hasProblems
            ? 'Sincronización con problemas: ${report.errorMessage ?? '${report.failed} operaciones fallidas'}'
            : 'Sincronización completada',
        metrics: report.toMetrics(),
      );
    }
    if (report.didWork && errorMessage == null) {
      await database.settingsDao.setValue(
        SettingsKeys.syncLastSuccessAt,
        DateTime.now().toUtc().toIso8601String(),
        syncToCloud: false,
      );
    }
    if (report.didWork) {
      await database.syncDao.housekeeping();
    }

    Log.info(_scope, report.toString());
    return report;
  }

  // ---------------------------------------------------------------------------
  // Empuje
  // ---------------------------------------------------------------------------

  Future<PushOutcome> _pushBatch(List<SyncOperationEnvelope> envelopes) async {
    try {
      final PushResponse response = await remote.push(envelopes);
      final Map<String, RemoteOperationResult> byOpId = <String, RemoteOperationResult>{
        for (final RemoteOperationResult result in response.results) result.opId: result,
      };

      final List<String> synced = <String>[];
      int conflicts = 0;
      int retried = 0;
      int failed = 0;

      for (final SyncOperationEnvelope envelope in envelopes) {
        final RemoteOperationResult? result = byOpId[envelope.opId];

        // El servidor no se pronunció sobre esta operación: se reintenta.
        if (result == null) {
          await _scheduleRetry(envelope, 'El servidor no confirmó la operación', 0);
          retried++;
          continue;
        }

        if (result.isSuccess) {
          synced.add(envelope.opId);
          continue;
        }

        if (result.status == RemoteOperationResult.statusConflict || result.conflict) {
          await database.syncDao.markResolvedByRemote(
            opId: envelope.opId,
            detail: result.message ?? 'La nube tenía una versión más nueva (LWW)',
          );
          conflicts++;
          continue;
        }

        if (result.status == RemoteOperationResult.statusRejected) {
          await database.syncDao.markFailed(
            opId: envelope.opId,
            attempts: envelope.attempt,
            error: result.message ?? 'Rechazado por el servidor',
          );
          failed++;
          continue;
        }

        // `retry`: fallo transitorio reportado por el servidor.
        await _scheduleRetry(envelope, result.message ?? 'Reintento solicitado', 0);
        retried++;
      }

      if (synced.isNotEmpty) {
        await database.syncDao.markSynced(synced);
      }

      return PushOutcome(
        applied: synced.length,
        conflicts: conflicts,
        retried: retried,
        failed: failed,
      );
    } on RemoteTransportException catch (error) {
      // Fallo de red o HTTP: TODAS las operaciones del lote se reprograman.
      for (final SyncOperationEnvelope envelope in envelopes) {
        await _scheduleRetry(
          envelope,
          error.message,
          error.httpStatus,
          // Un 4xx no recuperable agota los intentos de inmediato.
          forceGiveUp: !error.isRetryable,
        );
      }
      await database.syncDao.logEvent(
        level: error.isRetryable ? 'warning' : 'error',
        message: error.message,
        metrics: <String, Object?>{
          'http_status': error.httpStatus,
          'operations': envelopes.length,
          'retryable': error.isRetryable,
        },
      );
      return PushOutcome(
        applied: 0,
        conflicts: 0,
        retried: error.isRetryable ? envelopes.length : 0,
        failed: error.isRetryable ? 0 : envelopes.length,
        transportFailure: true,
        errorMessage: error.message,
      );
    } on Object catch (error, stack) {
      Log.error(_scope, 'Fallo inesperado al empujar lote', error: error, stackTrace: stack);
      for (final SyncOperationEnvelope envelope in envelopes) {
        await _scheduleRetry(envelope, error.toString(), 0);
      }
      return PushOutcome(
        applied: 0,
        conflicts: 0,
        retried: envelopes.length,
        failed: 0,
        transportFailure: true,
        errorMessage: error.toString(),
      );
    }
  }

  /// Programa el reintento de una operación (o la marca como fallida).
  Future<void> _scheduleRetry(
    SyncOperationEnvelope envelope,
    String errorMessage,
    int httpStatus, {
    bool forceGiveUp = false,
  }) async {
    final int attempt = envelope.attempt;
    if (forceGiveUp || backoff.shouldGiveUp(attempt)) {
      await database.syncDao.markFailed(
        opId: envelope.opId,
        attempts: attempt,
        error: errorMessage,
        httpStatus: httpStatus,
      );
      Log.warning(
        _scope,
        'Operación marcada como fallida tras $attempt intentos',
        data: <String, Object?>{
          'entity': envelope.entity.storageKey,
          'uuid': envelope.entityUuid,
        },
      );
      return;
    }
    await database.syncDao.markRetry(
      opId: envelope.opId,
      attempts: attempt,
      nextDelay: backoff.delayFor(attempt),
      error: errorMessage,
      httpStatus: httpStatus,
    );
  }

  // ---------------------------------------------------------------------------
  // Descarga
  // ---------------------------------------------------------------------------

  Future<int> _pullChanges() async {
    final RemoteApplier applier = RemoteApplier(database);
    int applied = 0;

    for (final SyncEntity entity in kPullableEntities) {
      final SyncCursor? cursor = await database.syncDao.cursorFor(entity);
      try {
        final PullResponse response = await remote.pull(
          entities: <SyncEntity>[entity],
          since: cursor?.lastPulledAt,
        );
        if (response.changes.isEmpty) {
          continue;
        }
        final ApplyOutcome outcome = await applier.apply(response.changes);
        applied += outcome.applied;
        await database.syncDao.saveCursor(
          entity: entity,
          lastPulledAt: response.cursor ?? DateTime.now().toUtc(),
          rowsApplied: outcome.applied,
        );
      } on RemoteTransportException catch (error) {
        // La descarga es best-effort: no debe impedir que las ventas suban.
        Log.warning(_scope, 'Descarga de ${entity.storageKey} omitida', error: error.message);
        break;
      }
    }
    return applied;
  }

  /// Decodifica el payload del outbox (JSON plano -> mapa).
  ///
  /// Se usa el decodificador del SDK (probado y rápido). El *encoder* sí es
  /// propio (ver `AppDatabase._jsonEncode`) porque necesita serializar tipos de
  /// dominio (`Money`, `Quantity`, enums) de forma controlada y estable.
  static Map<String, Object?> _decodePayload(String raw) {
    if (raw.isEmpty) return <String, Object?>{};
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return decoded.map((String key, Object? value) => MapEntry<String, Object?>(key, value));
      }
    } on FormatException catch (error) {
      Log.warning('sync_engine', 'Payload del outbox ilegible', error: error);
    }
    return <String, Object?>{};
  }
}

/// Resultado interno de un empuje.
class PushOutcome {
  const PushOutcome({
    required this.applied,
    required this.conflicts,
    required this.retried,
    required this.failed,
    this.transportFailure = false,
    this.errorMessage,
  });

  final int applied;
  final int conflicts;
  final int retried;
  final int failed;
  final bool transportFailure;
  final String? errorMessage;
}
