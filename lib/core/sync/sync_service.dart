import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

import '../config/app_config.dart';
import '../database/app_database.dart';
import '../database/daos/settings_dao.dart';
import '../logging/app_logger.dart';
import 'remote_api.dart';
import 'sync_engine.dart';
import 'sync_models.dart';

/// Servicio de sincronización en segundo plano.
///
/// Responsabilidades (y nada más):
///  * Vigilar el estado de la red con `connectivity_plus`.
///  * Disparar ciclos: al recuperar conexión, cada [AppConfig.syncInterval] y
///    a petición (tras una venta o desde el botón "Sincronizar ahora").
///  * Serializar los ciclos (**jamás dos a la vez**: dos empujes simultáneos
///    duplicarían trabajo y ensuciarían las métricas).
///  * Exponer un estado observable para la barra de estado de la interfaz.
///
/// El motor ([SyncEngine]) no sabe nada de esto: se puede probar sin red y sin
/// temporizadores, que es exactamente como debe probarse.
class SyncService {
  SyncService({
    required this.database,
    required this.remote,
    Connectivity? connectivity,
    SyncEngine? engine,
  })  : _connectivity = connectivity ?? Connectivity(),
        _engine = engine ??
            SyncEngine(
              database: database,
              remote: remote,
            );

  final AppDatabase database;
  final RemoteSyncApi remote;
  final Connectivity? _connectivity;
  final SyncEngine _engine;

  static const String _scope = 'sync';

  /// Tiempo mínimo entre ciclos automáticos (evita ráfagas de red).
  static const Duration _minAutomaticInterval = Duration(seconds: 8);

  /// Retardo del empuje "casi inmediato" tras una operación local.
  static const Duration _postWriteDelay = Duration(seconds: 2);

  final StreamController<SyncStatusSnapshot> _statusController =
      StreamController<SyncStatusSnapshot>.broadcast();

  SyncStatusSnapshot _status = SyncStatusSnapshot.idle;
  StreamSubscription<Object?>? _connectivitySubscription;
  Timer? _heartbeat;
  Timer? _debounce;
  Future<SyncCycleReport>? _runningCycle;
  DateTime? _lastCycleAt;
  bool _initialized = false;
  bool _disposed = false;
  bool _enabled = true;

  /// Estado actual (sin esperar al flujo).
  SyncStatusSnapshot get status => _status;

  /// Flujo de estado para la interfaz.
  Stream<SyncStatusSnapshot> watchStatus() => _statusController.stream;

  bool get isEnabled => _enabled;

  /// ¿Hay un ciclo en ejecución ahora mismo?
  bool get isSyncing => _runningCycle != null;

  /// Prepara el servicio: lee la configuración y arranca la vigilancia de red.
  Future<void> initialize() async {
    if (_initialized || _disposed) return;
    _initialized = true;

    _enabled = await database.settingsDao
        .boolValue(SettingsKeys.syncEnabled, fallback: remote.isConfigured);
    _status = _status.copyWith(network: _networkOf(await _checkConnectivity()));
    _emit();

    if (!remote.isConfigured) {
      Log.info(_scope, 'Sin backend configurado: UltraPOS opera 100 % local');
      await database.syncDao.logEvent(
        level: 'info',
        message: 'Modo local activo. Configure la nube en Configuración > Sincronización.',
      );
      return;
    }

    await _connectivity?.onConnectivityChanged.listen(
      (Object? results) => _onConnectivityChanged(_resultsOf(results)),
      onError: (Object error) => Log.warning(_scope, 'Fallo al vigilar la red', error: error),
    ).let<StreamSubscription<Object?>?>((StreamSubscription<Object?>? sub) {
      _connectivitySubscription = sub;
      return sub;
    });

    _startHeartbeat();
    // Primer ciclo diferido: no competir con el arranque de la aplicación.
    _debounce = Timer(const Duration(seconds: 4), () => unawaited(syncNow()));

    Log.info(
      _scope,
      'Servicio de sincronización iniciado',
      data: <String, Object?>{'backend': remote.description, 'enabled': _enabled},
    );
  }

  /// Habilita/deshabilita la sincronización (Configuración > Sincronización).
  Future<void> setEnabled(bool value) async {
    _enabled = value;
    await database.settingsDao.setValue(SettingsKeys.syncEnabled, value, syncToCloud: false);
    if (value) {
      await syncNow(manual: true);
    } else {
      _emit();
    }
  }

  /// Solicita un ciclo. Si ya hay uno en marcha, **se reutiliza** (no se
  /// duplica el trabajo de red).
  Future<SyncCycleReport> syncNow({bool manual = false, bool pullEnabled = true}) {
    final Future<SyncCycleReport>? running = _runningCycle;
    if (running != null) return running;

    if (!manual) {
      final DateTime now = DateTime.now();
      final DateTime? last = _lastCycleAt;
      if (last != null && now.difference(last) < _minAutomaticInterval) {
        return Future<SyncCycleReport>.value(
          SyncCycleReport.disabled(now.toUtc()),
        );
      }
    }

    final Future<SyncCycleReport> cycle = _runCycle(manual: manual, pullEnabled: pullEnabled);
    _runningCycle = cycle;
    return cycle;
  }

  Future<SyncCycleReport> _runCycle({required bool manual, required bool pullEnabled}) async {
    final DateTime startedAt = DateTime.now();
    _status = _status.copyWith(isSyncing: true, clearError: true);
    _emit();

    try {
      final bool online = manual ? true : _status.isOnline;
      final SyncCycleReport report = await _engine.runCycle(
        isOnline: online,
        pullEnabled: pullEnabled,
      );

      if (report.errorMessage != null) {
        // Comprobar de nuevo la red: un fallo de transporte suele ser el primer
        // indicio de que se cayó el enlace.
        final NetworkState detected = _networkOf(await _checkConnectivity());
        _status = _status.copyWith(
          network: detected.isOnline && report.errorMessage != null
              ? NetworkState.online
              : detected,
          lastError: report.errorMessage,
        );
      } else if (report.didWork) {
        _status = _status.copyWith(lastSyncAt: DateTime.now().toUtc(), clearError: true);
      }

      await _refreshCounters();
      return report;
    } on Object catch (error, stack) {
      // El motor ya captura sus errores; esto cubre fallos de infraestructura
      // (base de datos bloqueada, por ejemplo).
      Log.error(_scope, 'Fallo inesperado en el ciclo de sincronización', error: error, stackTrace: stack);
      _status = _status.copyWith(lastError: 'Error interno: $error');
      return SyncCycleReport(
        startedAt: startedAt.toUtc(),
        finishedAt: DateTime.now().toUtc(),
        pushed: 0,
        pulled: 0,
        conflicts: 0,
        retried: 0,
        failed: 0,
        errorMessage: '$error',
      );
    } finally {
      _runningCycle = null;
      _lastCycleAt = DateTime.now();
      _status = _status.copyWith(isSyncing: false, currentBatchSent: 0, currentBatchTotal: 0);
      _emit();
    }
  }

  /// Marca que se acaba de escribir algo local relevante (venta, ajuste...).
  ///
  /// Empuja pronto pero no en el acto: agrupar 2 segundos de actividad evita
  /// un ciclo por cada línea del carrito.
  void notifyLocalChanges() {
    if (!_initialized || !_enabled || _disposed) return;
    _debounce?.cancel();
    _debounce = Timer(_postWriteDelay, () => unawaited(syncNow(pullEnabled: false)));
  }

  /// Reintenta todas las operaciones con error.
  Future<void> retryFailed() async {
    await database.syncDao.retryAllFailed();
    await _refreshCounters();
    await syncNow(manual: true);
  }

  /// Descarta una operación concreta (acción del administrador).
  Future<void> discardOperation(String opId, {String? reason}) async {
    await database.syncDao.discardEntry(opId, reason: reason);
    await _refreshCounters();
  }

  /// Reencola todo el histórico (recuperación tras un cambio de backend).
  Future<int> requeueAll() async {
    final int count = await database.syncDao.requeueAll();
    await _refreshCounters();
    return count;
  }

  /// Dispara un ciclo inmediato sin cumplir el intervalo mínimo.
  Future<void> forceSync() => syncNow(manual: true).then((_) {});

  Future<void> _refreshCounters() async {
    final SyncQueueStats stats = await database.syncDao.stats();
    _status = _status.copyWith(
      pendingCount: stats.outstanding,
      failedCount: stats.failed,
      lastSyncAt: stats.lastSyncedAt,
    );
    _emit();
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(AppConfig.syncInterval, (_) {
      if (_disposed || !_enabled) return;
      unawaited(syncNow());
    });
  }

  Future<void> _onConnectivityChanged(List<ConnectivityResult> results) async {
    final NetworkState previous = _status.network;
    final NetworkState current = _networkOf(results);
    _status = _status.copyWith(network: current);
    _emit();

    if (previous != current) {
      Log.info(
        _scope,
        'Estado de red: ${current.label}',
        data: <String, Object?>{'interfaces': results.map((ConnectivityResult r) => r.name).toList()},
      );
    }

    // Al recuperar la conexión se sincroniza de inmediato: el cajero acaba de
    // volver a estar en línea y sus ventas ya deberían estar subiendo.
    if (current.isOnline && previous != NetworkState.online && _enabled) {
      await syncNow(manual: true);
    }
  }

  Future<List<ConnectivityResult>> _checkConnectivity() async {
    if (_connectivity == null) return <ConnectivityResult>[ConnectivityResult.other];
    try {
      return _resultsOf(await _connectivity!.checkConnectivity());
    } on Object catch (error) {
      Log.warning(_scope, 'No se pudo consultar la conectividad', error: error);
      return <ConnectivityResult>[ConnectivityResult.other];
    }
  }

  /// Normaliza la respuesta de `connectivity_plus`: en v6+ es una lista, en
  /// versiones anteriores un valor único. Soportar ambas formas evita un fallo
  /// silencioso al actualizar la dependencia.
  static List<ConnectivityResult> _resultsOf(Object? value) {
    if (value is List) {
      return value.whereType<ConnectivityResult>().toList(growable: false);
    }
    if (value is ConnectivityResult) return <ConnectivityResult>[value];
    return <ConnectivityResult>[];
  }

  static NetworkState _networkOf(List<ConnectivityResult> results) {
    if (results.isEmpty) return NetworkState.offline;
    final bool connected = results.any(
      (ConnectivityResult result) => result != ConnectivityResult.none,
    );
    return connected ? NetworkState.online : NetworkState.offline;
  }

  void _emit() {
    if (_disposed || _statusController.isClosed) return;
    _statusController.add(_status);
  }

  Future<void> dispose() async {
    _disposed = true;
    _heartbeat?.cancel();
    _debounce?.cancel();
    await _connectivitySubscription?.cancel();
    await _statusController.close();
  }
}

/// Utilidad de encadenamiento legible para asignar una suscripción.
extension _Let<T> on T {
  R let<R>(R Function(T value) transform) => transform(this);
}
