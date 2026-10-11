import 'package:flutter/foundation.dart';

import '../theme/app_spacing.dart';

/// Entorno de ejecución. Se define en compilación:
/// `flutter build windows --release --dart-define=ULTRAPOS_ENV=production`
enum AppEnvironment { development, staging, production }

/// Configuración global de UltraPOS.
///
/// Todo lo que cambia entre desarrollo y producción viene de `--dart-define`,
/// de modo que **no hay secretos ni URLs hardcodeadas en el binario** por
/// accidente: si no se define, la app arranca en modo local (sin nube), que es
/// exactamente el comportamiento deseado en un POS offline-first.
abstract final class AppConfig {
  // --- Identidad -----------------------------------------------------------
  static const String appName = 'UltraPOS';
  static const String appVersion = '1.0.0';
  static const String companyFallbackName = 'UltraPOS';

  // --- Entorno -------------------------------------------------------------
  static const String _env = String.fromEnvironment(
    'ULTRAPOS_ENV',
    defaultValue: 'development',
  );

  static AppEnvironment get environment => switch (_env) {
        'production' => AppEnvironment.production,
        'staging' => AppEnvironment.staging,
        _ => AppEnvironment.development,
      };

  static bool get isProduction => environment == AppEnvironment.production;
  static bool get isDevelopment => environment == AppEnvironment.development;

  /// Log detallado (SQL, sync, hardware). Nunca en producción.
  static bool get verboseLogging => isDevelopment;

  /// Activa la traza SQL de Drift. Degrada el rendimiento: solo en desarrollo.
  static const bool logSqlStatements = bool.fromEnvironment(
    'ULTRAPOS_LOG_SQL',
    defaultValue: false,
  );

  // --- Sincronización ------------------------------------------------------
  /// Endpoint REST de sincronización (nulo = modo solo local).
  static const String syncBaseUrl = String.fromEnvironment('ULTRAPOS_SYNC_URL');

  /// Clave publicable de Supabase (segura para el cliente).
  static const String supabaseUrl = String.fromEnvironment('ULTRAPOS_SUPABASE_URL');
  static const String supabaseAnonKey = String.fromEnvironment(
    'ULTRAPOS_SUPABASE_ANON_KEY',
  );

  static bool get hasCloudBackend =>
      syncBaseUrl.isNotEmpty || (supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty);

  /// Reintentos: retroceso exponencial acotado.
  static const Duration syncBackoffBase = Duration(seconds: 3);
  static const Duration syncBackoffMax = Duration(minutes: 15);

  /// Tamaño máximo de un lote de operaciones enviado a la nube.
  static const int syncBatchSize = 40;

  /// Máximo de lotes procesados por ciclo (evita monopolizar el isolate).
  static const int syncMaxBatchesPerCycle = 20;

  /// Un registro que falló [syncMaxAttempts] veces pasa a estado `failed`
  /// y se muestra al administrador en el panel de sincronización.
  static const int syncMaxAttempts = 12;

  /// Intervalo del latido de sincronización en segundo plano.
  static const Duration syncInterval = AppDurations.syncHeartbeat;

  /// Tiempo máximo de espera de una petición HTTP.
  static const Duration httpTimeout = Duration(seconds: 25);

  // --- Base de datos -------------------------------------------------------
  static const String databaseName = 'ultrapos';

  /// Cifrado del archivo SQLite con SQLCipher.
  ///
  /// Se activa con `--dart-define=ULTRAPOS_DB_ENCRYPTION=true` y requiere el
  /// paquete `sqlcipher_flutter_libs` (ver docs/WINDOWS_SETUP.md). La clave se
  /// guarda en el almacén seguro de Windows (DPAPI) vía flutter_secure_storage.
  static const bool databaseEncryptionEnabled = bool.fromEnvironment(
    'ULTRAPOS_DB_ENCRYPTION',
    defaultValue: false,
  );

  /// Retención de respaldos automáticos locales.
  static const int maxLocalBackups = 7;

  // --- Negocio (valores por defecto, sobreescribibles en Configuración) ----
  static const int defaultTaxRateBps = 1600; // IVA 16%
  static const bool defaultTaxIncludedInPrice = true;
  static const double defaultLowStockMultiplier = 1.0;
  static const String defaultCurrencyCode = 'NIO';
  static const String defaultCurrencySymbol = r'C$';
  static const String defaultLocale = 'es';

  /// Tolerancia de redondeo al cuadrar pagos mixtos (en centavos).
  /// Si el cajero paga 0.02 de menos por redondeo de tarjeta, no bloqueamos.
  static const int paymentRoundingToleranceCents = 0;

  // --- UI / Escritorio -----------------------------------------------------
  static const String windowTitle = 'UltraPOS - Punto de Venta';

  /// Denominaciones para el arqueo de caja (en centavos, de menor a mayor).
  ///
  /// Corresponde al cono monetario habitual de la región (monedas de 5, 10, 25
  /// y 50 centavos, 1 y 5 unidades; billetes de 10 a 1000). Es la hoja de
  /// conteo que se imprime y se firma al cerrar el turno.
  static const List<int> cashDenominationsCents = <int>[
    5,
    10,
    25,
    50,
    100,
    500,
    1000,
    2000,
    5000,
    10000,
    20000,
    50000,
    100000,
  ];

  /// Subtítulo mostrado en la barra de título propia.
  static const String windowSubtitle = 'Punto de Venta';
  static const double minWindowWidth = 1366;
  static const double minWindowHeight = 768;
  static const double defaultWindowWidth = 1440;
  static const double defaultWindowHeight = 900;

  /// Debounce del lector de código de barras (diferencia tecleo humano vs.
  /// ráfaga del scanner). 50 ms es el estándar de la industria.
  static const Duration scannerBurstWindow = Duration(milliseconds: 50);

  /// Mínimo de caracteres para buscar productos.
  static const int minSearchChars = 1;

  /// Filas por página en las tablas del sistema.
  static const int tablePageSize = 25;

  /// Tiempo para revertir una acción destructiva (anular venta).
  static const Duration undoGracePeriod = Duration(minutes: 10);

  /// Atajos de teclado: se definen en un solo lugar para documentarlos y
  /// mostrarlos en la barra de estado.
  static const Map<String, String> shortcutLegend = <String, String>{
    'F1': 'Ayuda',
    'F2': 'Buscar',
    'F3': 'Cliente',
    'F4': 'Ventas en espera',
    'F5': 'Sincronizar',
    'F6': 'Descuento',
    'F7': 'Cantidad',
    'F8': 'Retirar línea',
    'F9': 'Pago mixto',
    'F10': 'Abrir cajón',
    'F12': 'COBRAR',
    'Ctrl+P': 'Reimprimir último',
    'Ctrl+L': 'Cerrar sesión',
    'Esc': 'Cancelar',
  };

  /// Firma el guardado de configuración local (evita ficheros corruptos).
  static const int settingsSchemaVersion = 1;

  /// Descripción corta del dispositivo usada si falla la detección del host.
  static String get defaultDeviceName => defaultTargetPlatform == TargetPlatform.windows
      ? 'CAJA-PRINCIPAL'
      : 'DISPOSITIVO';
}
