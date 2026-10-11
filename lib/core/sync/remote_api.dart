import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:http/http.dart' as http;

import '../domain/enums.dart';
import '../logging/app_logger.dart';
import 'sync_models.dart';

/// Entidades maestras que se **descargan** de la nube.
///
/// Decisión de arquitectura: el flujo es asimétrico y deliberado.
///  * **Suben** todas las entidades (ventas, caja, inventario, catálogo...):
///    la caja es la fuente de verdad de lo que ocurrió en el mostrador.
///  * **Bajan** solo los datos maestros (catálogo, precios, clientes,
///    usuarios, configuración): así una central puede publicar precios y
///    alta de productos sin pisar jamás una venta.
///
/// Bajar ventas a una caja no aporta nada y sí introduce riesgo de duplicar.
const List<SyncEntity> kPullableEntities = <SyncEntity>[
  SyncEntity.company,
  SyncEntity.setting,
  SyncEntity.category,
  SyncEntity.product,
  SyncEntity.customer,
  SyncEntity.user,
];

/// Contrato del transporte remoto.
abstract interface class RemoteSyncApi {
  bool get isConfigured;

  String get description;

  /// Envía un lote de operaciones. Debe ser **idempotente** por `op_id`.
  Future<PushResponse> push(List<SyncOperationEnvelope> operations);

  /// Descarga cambios desde el cursor indicado.
  Future<PullResponse> pull({
    required List<SyncEntity> entities,
    DateTime? since,
    int limit,
  });

  /// Comprobación ligera de disponibilidad (no bloquea la operación del POS).
  Future<bool> ping();
}

/// Error de transporte con información para decidir si se reintenta.
class RemoteTransportException implements Exception {
  const RemoteTransportException(this.message, {this.httpStatus = 0, this.isRetryable = true});

  final String message;
  final int httpStatus;

  /// `false` para 4xx de autenticación/validación: reintentar no ayuda.
  final bool isRetryable;

  @override
  String toString() => 'RemoteTransportException($httpStatus): $message';
}

// ---------------------------------------------------------------------------
// Petición HTTP ejecutada en un isolate de fondo
// ---------------------------------------------------------------------------

/// Ejecuta una petición HTTP **en un isolate de fondo**.
///
/// Es una función de nivel superior (no un método) para que pueda capturarse
/// desde `Isolate.run`. El request/response son mapas de primitivas, por lo que
/// cruzan la frontera del isolate sin problemas.
///
/// Ganancia real: codificar/decodificar un lote de 40 ventas con sus líneas
/// cuesta milisegundos que **no** se le roban al hilo de la interfaz. En una
/// caja que está cobrando, eso se nota.
Future<Map<String, Object?>> isolateHttpRequest(Map<String, Object?> request) async {
  final String url = '${request['url']}';
  final String method = '${request['method'] ?? 'POST'}';
  final Map<String, String> headers = <String, String>{
    for (final MapEntry<Object?, Object?> entry
        in (request['headers'] as Map<Object?, Object?>? ?? <Object?, Object?>{}).entries)
      '${entry.key}': '${entry.value}',
  };
  final String? body = request['body'] as String?;
  final int timeoutSeconds = (request['timeout_seconds'] as num?)?.toInt() ?? 25;

  final client = http.Client();
  try {
    final Uri uri = Uri.parse(url);
    final Future<http.Response> future = switch (method) {
      'GET' => client.get(uri, headers: headers),
      'PUT' => client.put(uri, headers: headers, body: body),
      _ => client.post(uri, headers: headers, body: body),
    };
    final http.Response response = await future.timeout(Duration(seconds: timeoutSeconds));
    return <String, Object?>{
      'ok': true,
      'status': response.statusCode,
      'body': response.body,
    };
  } on Object catch (error, stack) {
    return <String, Object?>{
      'ok': false,
      'status': 0,
      'error': error.toString(),
      'stack': stack.toString(),
    };
  } finally {
    client.close();
  }
}

/// API REST genérica compatible con cualquier backend (Node, .NET, Laravel...).
///
/// Endpoints esperados:
///  * `POST {baseUrl}/sync/push` → `{ results: [...], server_time, pull_cursor }`
///  * `POST {baseUrl}/sync/pull` → `{ changes: [...], cursor }`
///  * `GET  {baseUrl}/health`    → 200
class HttpRemoteApi implements RemoteSyncApi {
  HttpRemoteApi(this.config, {IsolateRunner? isolateRunner})
      : _runInIsolate = isolateRunner ?? Isolate.run;

  final RemoteConfig config;

  /// Inyectable para tests (evita crear isolates en memoria).
  final IsolateRunner _runInIsolate;

  @override
  bool get isConfigured => config.isConfigured;

  @override
  String get description => 'REST · ${config.baseUrl}';

  Map<String, String> get _headers => <String, String>{
        'Content-Type': 'application/json; charset=utf-8',
        'Accept': 'application/json',
        'X-UltraPOS-Device': config.deviceId,
        if (config.apiKey.isNotEmpty) 'Authorization': 'Bearer ${config.apiKey}',
      };

  @override
  Future<PushResponse> push(List<SyncOperationEnvelope> operations) async {
    if (operations.isEmpty) {
      return const PushResponse(results: <RemoteOperationResult>[]);
    }
    final Map<String, Object?> body = <String, Object?>{
      'device_id': config.deviceId,
      'sent_at': DateTime.now().toUtc().toIso8601String(),
      'operations': operations
          .map((SyncOperationEnvelope op) => op.toJson())
          .toList(growable: false),
    };

    final Map<String, Object?> json = await _send(
      path: '/sync/push',
      body: body,
      operationCount: operations.length,
    );
    return PushResponse.fromJson(json);
  }

  @override
  Future<PullResponse> pull({
    required List<SyncEntity> entities,
    DateTime? since,
    int limit = 500,
  }) async {
    final Map<String, Object?> json = await _send(
      path: '/sync/pull',
      body: <String, Object?>{
        'device_id': config.deviceId,
        'entities': entities.map((SyncEntity e) => e.storageKey).toList(growable: false),
        'since': since?.toUtc().toIso8601String(),
        'limit': limit,
      },
    );
    return PullResponse.fromJson(json);
  }

  @override
  Future<bool> ping() async {
    final Map<String, Object?> response = await _runInIsolate(
      () => isolateHttpRequest(<String, Object?>{
        'url': '${config.baseUrl}/health',
        'method': 'GET',
        'headers': _headers,
        'timeout_seconds': 8,
      }),
    );
    return response['ok'] == true && (response['status'] as num? ?? 0) < 400;
  }

  Future<Map<String, Object?>> _send({
    required String path,
    required Map<String, Object?> body,
    int operationCount = 0,
  }) async {
    final String url = '${config.baseUrl}$path';
    final String encoded = jsonEncode(body);

    final Map<String, Object?> response = await _runInIsolate(
      () => isolateHttpRequest(<String, Object?>{
        'url': url,
        'method': 'POST',
        'headers': _headers,
        'body': encoded,
        'timeout_seconds': config.timeoutSeconds,
      }),
    );

    if (response['ok'] != true) {
      final String error = '${response['error'] ?? 'Fallo de red desconocido'}';
      Log.warning('sync', 'Fallo de transporte en $path', error: error);
      throw RemoteTransportException(
        'No se pudo contactar el servidor de sincronización.',
        httpStatus: 0,
        isRetryable: true,
      );
    }

    final int status = (response['status'] as num?)?.toInt() ?? 0;
    final String rawBody = '${response['body'] ?? ''}';

    if (status >= 200 && status < 300) {
      if (rawBody.trim().isEmpty) return <String, Object?>{};
      final Object? decoded = jsonDecode(rawBody);
      if (decoded is Map<Object?, Object?>) {
        return decoded.map((Object? k, Object? v) => MapEntry<String, Object?>('$k', v));
      }
      throw RemoteTransportException(
        'Respuesta inesperada del servidor (se esperaba un objeto JSON).',
        httpStatus: status,
        isRetryable: false,
      );
    }

    // 408/429/5xx son transitorios; 400/401/403/404 no lo son.
    final bool retryable = status == 408 || status == 429 || status >= 500;
    Log.warning(
      'sync',
      'HTTP $status en $path',
      data: <String, Object?>{'body': rawBody.length > 300 ? rawBody.substring(0, 300) : rawBody},
    );
    throw RemoteTransportException(
      _humanMessage(status),
      httpStatus: status,
      isRetryable: retryable,
    );
  }

  String _humanMessage(int status) => switch (status) {
        400 => 'El servidor rechazó los datos enviados (400).',
        401 || 403 => 'Clave de sincronización inválida o expirada.',
        404 => 'La dirección de sincronización no existe (404).',
        408 => 'El servidor tardó demasiado en responder (408).',
        429 => 'Demasiadas peticiones al servidor (429).',
        >= 500 => 'El servidor de sincronización está fallando ($status).',
        _ => 'Respuesta inesperada del servidor ($status).',
      };
}

/// Firma del ejecutor de isolates (inyectable en tests).
typedef IsolateRunner = Future<R> Function<R>(FutureOr<R> Function() computation);

// ---------------------------------------------------------------------------
// Backend simulado
// ---------------------------------------------------------------------------

/// Backend en memoria: permite demostrar y **probar** el motor de
/// sincronización completo sin infraestructura.
///
/// Simula lo que más duele en producción: latencia, cortes de red, respuestas
/// duplicadas y conflictos de versión. Es la herramienta con la que se
/// verifican los reintentos y la idempotencia antes de tocar la nube real.
class MockRemoteApi implements RemoteSyncApi {
  MockRemoteApi({
    this.latency = const Duration(milliseconds: 120),
    this.failureRate = 0.0,
    this.nowProvider,
  });

  /// Latencia simulada por petición.
  final Duration latency;

  /// Probabilidad (0..1) de que una petición falle de forma transitoria.
  final double failureRate;

  final DateTime Function()? nowProvider;

  /// Operaciones ya aplicadas (idempotencia por `op_id`).
  final Map<String, Map<String, Object?>> appliedOperations = <String, Map<String, Object?>>{};

  /// Estado remoto por entidad (`entity:uuid` -> payload).
  final Map<String, Map<String, Object?>> remoteState = <String, Map<String, Object?>>{};

  int pushCalls = 0;
  int pullCalls = 0;

  DateTime get _now => (nowProvider ?? DateTime.now)();

  @override
  bool get isConfigured => true;

  @override
  String get description => 'Demonstración (memoria)';

  @override
  Future<bool> ping() async {
    await Future<void>.delayed(latency);
    return failureRate < 1.0;
  }

  @override
  Future<PushResponse> push(List<SyncOperationEnvelope> operations) async {
    pushCalls++;
    await Future<void>.delayed(latency);
    if (_shouldFail()) {
      throw const RemoteTransportException(
        'Fallo de red simulado',
        httpStatus: 503,
        isRetryable: true,
      );
    }

    final List<RemoteOperationResult> results = <RemoteOperationResult>[];
    for (final SyncOperationEnvelope operation in operations) {
      final bool duplicate = appliedOperations.containsKey(operation.opId);
      final String key = '${operation.entity.storageKey}:${operation.entityUuid}';
      final Map<String, Object?>? existing = remoteState[key];
      final DateTime? remoteUpdatedAt = existing == null
          ? null
          : DateTime.tryParse('${existing['updated_at']}')?.toUtc();

      // Last Write Wins: si el remoto tiene una versión más nueva gana la nube.
      if (remoteUpdatedAt != null && remoteUpdatedAt.isAfter(operation.lwwTimestamp)) {
        results.add(RemoteOperationResult(
          opId: operation.opId,
          status: RemoteOperationResult.statusConflict,
          conflict: true,
          serverUpdatedAt: remoteUpdatedAt,
          message: 'La nube tiene una versión más reciente',
        ));
        continue;
      }

      appliedOperations[operation.opId] = <String, Object?>{
        'entity': operation.entity.storageKey,
        'entity_id': operation.entityUuid,
        'applied_at': _now.toUtc().toIso8601String(),
      };
      remoteState[key] = <String, Object?>{
        ...operation.payload,
        'updated_at': operation.lwwTimestamp.toUtc().toIso8601String(),
        'sync_version': (existing?['sync_version'] as int? ?? 0) + 1,
      };

      results.add(RemoteOperationResult(
        opId: operation.opId,
        status: duplicate
            ? RemoteOperationResult.statusDuplicate
            : RemoteOperationResult.statusApplied,
        serverUpdatedAt: operation.lwwTimestamp,
      ));
    }

    return PushResponse(
      results: results,
      serverTime: _now.toUtc(),
      pullCursor: _now.toUtc(),
    );
  }

  @override
  Future<PullResponse> pull({
    required List<SyncEntity> entities,
    DateTime? since,
    int limit = 500,
  }) async {
    pullCalls++;
    await Future<void>.delayed(latency);
    if (_shouldFail()) {
      throw const RemoteTransportException(
        'Fallo de red simulado',
        httpStatus: 503,
        isRetryable: true,
      );
    }

    final List<RemoteChange> changes = <RemoteChange>[];
    for (final MapEntry<String, Map<String, Object?>> entry in remoteState.entries) {
      final String entityKey = entry.key.split(':').first;
      final SyncEntity? entity = SyncEntity.tryFromStorage(entityKey);
      if (entity == null || !entities.contains(entity)) continue;
      final DateTime updatedAt =
          DateTime.tryParse('${entry.value['updated_at']}')?.toUtc() ?? _now.toUtc();
      if (since != null && !updatedAt.isAfter(since)) continue;
      changes.add(RemoteChange(
        entity: entity,
        entityUuid: entry.key.split(':').last,
        operation: SyncOperation.update,
        payload: entry.value,
        updatedAt: updatedAt,
        serverVersion: entry.value['sync_version'] as int? ?? 1,
      ));
      if (changes.length >= limit) break;
    }

    return PullResponse(changes: changes, cursor: _now.toUtc());
  }

  bool _shouldFail() {
    if (failureRate <= 0) return false;
    if (failureRate >= 1) return true;
    // Aleatoriedad reproducible suficiente para pruebas de reintentos.
    return DateTime.now().microsecondsSinceEpoch % 1000 < (failureRate * 1000);
  }
}

/// API "null object": la aplicación funciona 100 % local sin configuración.
class LocalOnlyRemoteApi implements RemoteSyncApi {
  const LocalOnlyRemoteApi();

  @override
  bool get isConfigured => false;

  @override
  String get description => 'Solo local (sin nube configurada)';

  @override
  Future<bool> ping() async => false;

  @override
  Future<PushResponse> push(List<SyncOperationEnvelope> operations) async =>
      const PushResponse(results: <RemoteOperationResult>[]);

  @override
  Future<PullResponse> pull({
    required List<SyncEntity> entities,
    DateTime? since,
    int limit = 500,
  }) async =>
      const PullResponse(changes: <RemoteChange>[]);
}
