import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../core/config/app_config.dart';
import '../core/database/app_database.dart';
import '../core/database/daos/settings_dao.dart';
import '../core/database/database_connection.dart';
import '../core/hardware/hardware_manager.dart';
import '../core/logging/app_logger.dart';
import '../core/providers.dart';
import '../core/security/secure_storage_service.dart';
import '../core/sync/remote_api.dart';
import '../core/sync/sync_models.dart';
import '../core/sync/sync_service.dart';
import '../core/utils/formatters.dart';
import 'app.dart';

/// Arranque de la aplicación.
///
/// Orden deliberado (cada paso depende del anterior):
///   1. **Logger**: cualquier fallo posterior debe quedar registrado.
///   2. **Ventana**: si algo tarda, el usuario ya ve la ventana y no cree que
///      la aplicación se colgó (percepción de rendimiento en escritorio).
///   3. **Secretos** (DPAPI): clave de base de datos y uuid del dispositivo.
///   4. **Base de datos** local: la fuente de verdad del POS.
///   5. **Dispositivo y valores por defecto**: folio, moneda, impuestos.
///   6. **Sincronización**: arranca en segundo plano, nunca bloquea la venta.
class Bootstrap {
  Bootstrap._();

  static const String _scope = 'bootstrap';

  /// Ejecuta el arranque completo y devuelve el ámbito de Riverpod.
  static Future<ProviderContainer> run() async {
    final WidgetsFlutterBinding binding = WidgetsFlutterBinding.ensureInitialized();

    final AppLogger logger = AppLogger.instance;
    await logger.initialize(logDirectory: DatabaseConnection.defaultLogDirectory());

    Log.info(_scope, 'Iniciando ${AppConfig.appName} ${AppConfig.appVersion}');

    await _prepareWindow(binding);

    // --- Secretos del equipo -------------------------------------------------
    final SecureStorageService secureStorage = SecureStorageService();
    final String deviceUuid = await secureStorage.readOrCreate(
      SecureKeys.deviceUuid,
      () => _newDeviceUuid(),
    );

    // --- Base de datos -------------------------------------------------------
    final DatabaseConnection connection = DatabaseConnection(secureStorage: secureStorage);
    final AppDatabase database = AppDatabase(
      connection.build(),
      deviceUuid: deviceUuid,
      deviceName: _hostName(),
    );

    // Fuerza la apertura real: si hay un problema (permisos, cifrado mal
    // configurado), es mejor saberlo ahora y no en medio de un cobro.
    await database.customSelect('SELECT 1;').get();

    Log.info(_scope, 'Base de datos lista', data: <String, Object?>{
      'file': connection.resolveDatabaseFile().path,
      'encrypted': AppConfig.databaseEncryptionEnabled,
    });

    // --- Dispositivo y configuración inicial ---------------------------------
    await database.settingsDao.ensureDevice(
      deviceUuid: deviceUuid,
      name: _hostName(),
      folioPrefix: _folioPrefix(),
      hostname: _hostName(),
      appVersion: AppConfig.appVersion,
    );
    await _seedDefaults(database);

    // --- Hardware ------------------------------------------------------------
    final HardwareManager hardware = HardwareManager(database: database);

    // --- Sincronización ------------------------------------------------------
    final SyncService syncService = _buildSyncService(database, deviceUuid);

    // --- Contenedor de dependencias -----------------------------------------
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        appDatabaseProvider.overrideWithValue(database),
        syncServiceProvider.overrideWithValue(syncService),
        hardwareManagerProvider.overrideWithValue(hardware),
      ],
    );

    // Arranca el motor de sincronización sin bloquear la interfaz: una caja
    // debe poder vender aunque la nube esté caída.
    unawaited(syncService.initialize());

    return container;
  }

  /// Configura la ventana nativa: tamaño mínimo, título y centrado.
  ///
  /// `window_manager` permite controlar la ventana real de Windows (minimizar,
  /// maximizar, recordar posición). Sin esto, una aplicación Flutter de
  /// escritorio se siente ajena al sistema.
  static Future<void> _prepareWindow(WidgetsFlutterBinding binding) async {
    try {
      await windowManager.ensureInitialized();

      final WindowOptions options = WindowOptions(
        size: const Size(AppConfig.defaultWindowWidth, AppConfig.defaultWindowHeight),
        minimumSize: const Size(AppConfig.minWindowWidth, AppConfig.minWindowHeight),
        center: true,
        title: AppConfig.windowTitle,
        backgroundColor: const Color(0xFFF5F7FA),
        titleBarStyle: TitleBarStyle.hidden,
        skipTaskbar: false,
      );

      await windowManager.waitUntilReadyToShow(options, () async {
        await windowManager.setResizable(true);
        await windowManager.setMinimumSize(
          const Size(AppConfig.minWindowWidth, AppConfig.minWindowHeight),
        );
        await windowManager.show();
        await windowManager.focus();
      });
    } on Object catch (error) {
      // Si el gestor de ventanas falla (por ejemplo, en un entorno sin
      // escritorio), la aplicación sigue funcionando con la ventana por
      // defecto: la venta es más importante que la decoración.
      Log.warning(_scope, 'No se pudo configurar la ventana: $error');
    }
  }

  /// Valores por defecto de un equipo recién instalado.
  static Future<void> _seedDefaults(AppDatabase database) async {
    final SettingsDao settings = database.settingsDao;
    await settings.setIfAbsent(SettingsKeys.taxRateBps, AppConfig.defaultTaxRateBps);
    await settings.setIfAbsent(SettingsKeys.taxIncluded, AppConfig.defaultTaxIncludedInPrice);
    await settings.setIfAbsent(SettingsKeys.requireOpenSession, true);
    await settings.setIfAbsent(SettingsKeys.allowNegativeStock, false);
    await settings.setIfAbsent(SettingsKeys.allowCreditSales, true);
    await settings.setIfAbsent(SettingsKeys.syncEnabled, true);
    await settings.setIfAbsent(SettingsKeys.showShortcutHints, true);
    await settings.ensureCompanyProfile(legalName: AppConfig.companyFallbackName);
    Log.info(_scope, 'Configuración por defecto verificada');
  }

  /// Crea el motor de sincronización según haya nube configurada o no.
  static SyncService _buildSyncService(AppDatabase database, String deviceUuid) {
    final RemoteConfig config = RemoteConfig(
      baseUrl: AppConfig.syncBaseUrl,
      deviceId: deviceUuid,
      apiKey: AppConfig.supabaseAnonKey,
    );

    final RemoteSyncApi remote =
        config.isConfigured ? HttpRemoteApi(config) : const LocalOnlyRemoteApi();

    Log.info(_scope, 'Sincronización: ${remote.description}');
    return SyncService(database: database, remote: remote);
  }

  static String _hostName() {
    try {
      final String name = Platform.localHostname.trim().toUpperCase();
      if (name.isEmpty) return AppConfig.defaultDeviceName;
      return name.length > 24 ? name.substring(0, 24) : name;
    } on Object {
      return AppConfig.defaultDeviceName;
    }
  }

  /// Prefijo de folios por equipo (`A`, `B`, `C`…) derivado del nombre.
  ///
  /// Cada caja emite su propia serie para que dos terminales offline puedan
  /// vender a la vez sin repetir folios.
  static String _folioPrefix() {
    final String name = _hostName();
    final RegExpMatch? digit = RegExp(r'(\d{1,2})').firstMatch(name);
    if (digit != null) {
      final int index = int.tryParse(digit.group(1)!) ?? 1;
      final int letter = ((index - 1) % 26) + 65;
      return String.fromCharCode(letter);
    }
    return 'A';
  }

  static String _newDeviceUuid() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-'
      '${Platform.localHostname.hashCode.toRadixString(36)}';

  /// Formato monetario del negocio (se construye tras conocer la configuración).
  static Future<CurrencyFormat> currencyFormat(AppDatabase database) async {
    final CompanyProfile profile =
        await database.settingsDao.ensureCompanyProfile(legalName: AppConfig.companyFallbackName);
    return CurrencyFormat(code: profile.currencyCode, symbol: profile.currencySymbol);
  }
}

/// Espera a una operación sin propagar errores (uso explícito y documentado).
void unawaited(Future<void> future) {
  future.catchError((Object error) {
    Log.warning('bootstrap', 'Tarea en segundo plano falló: $error');
  });
}
