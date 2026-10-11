import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'config/app_config.dart';
import 'database/app_database.dart';
import 'database/daos/cash_dao.dart';
import 'database/daos/sales_dao.dart';
import 'database/daos/settings_dao.dart';
import 'database/daos/sync_dao.dart';
import 'database/daos/users_dao.dart';
import 'domain/enums.dart';
import 'hardware/hardware_manager.dart';
import 'hardware/printer_config.dart';
import 'sync/sync_models.dart';
import 'sync/sync_service.dart';
import 'utils/formatters.dart';

/// Proveedores de infraestructura.
///
/// `appDatabaseProvider` y `syncServiceProvider` **must be overridden** en el
/// arranque (`bootstrap.dart`): así la aplicación tiene una única instancia de
/// la base de datos y del motor de sincronización, y las pruebas pueden inyectar
/// versiones en memoria o simuladas.
final appDatabaseProvider = Provider<AppDatabase>(
  (Ref ref) => throw UnimplementedError(
    'appDatabaseProvider debe sobrescribirse en el arranque.',
  ),
);

final hardwareManagerProvider = Provider<HardwareManager>(
  (Ref ref) => HardwareManager(database: ref.watch(appDatabaseProvider)),
);

final syncServiceProvider = Provider<SyncService>(
  (Ref ref) => throw UnimplementedError(
    'syncServiceProvider debe sobrescribirse en el arranque.',
  ),
);

// -----------------------------------------------------------------------------
// Sincronización
// -----------------------------------------------------------------------------

/// Estado de sincronización en vivo (barra de estado y pantalla de ajustes).
final syncStatusProvider = StreamProvider<SyncStatusSnapshot>(
  (Ref ref) => ref.watch(syncServiceProvider).watchStatus(),
);

/// Estadísticas de la cola de sincronización (pendientes, errores, atraso).
final syncQueueStatsProvider = StreamProvider<SyncQueueStats>((Ref ref) async* {
  final SyncDao dao = ref.watch(appDatabaseProvider).syncDao;
  // El DAO emite una señal cada vez que la cola cambia; se recalcula el
  // resumen completo (una consulta agregada) solo entonces.
  await for (final _ in dao.watchPendingCount()) {
    yield await dao.stats();
  }
});

/// Cola de sincronización observable (diagnóstico en Configuración > Sync).
final syncQueueProvider = StreamProvider((Ref ref) {
  return ref.watch(appDatabaseProvider).syncDao.watchQueue();
});

/// Bitácora de sincronización (últimos eventos, para soporte técnico).
final syncEventsProvider = StreamProvider((Ref ref) {
  return ref.watch(appDatabaseProvider).syncDao.watchEvents(limit: 100);
});

// -----------------------------------------------------------------------------
// Configuración del negocio
// -----------------------------------------------------------------------------

final companyProfileProvider = StreamProvider<CompanyProfile>((Ref ref) async* {
  final SettingsDao dao = ref.watch(appDatabaseProvider).settingsDao;
  await dao.ensureCompanyProfile(legalName: AppConfig.companyFallbackName);
  await for (final CompanyProfile? profile in dao.watchCompanyProfile()) {
    if (profile != null) yield profile;
  }
});

/// Formato monetario del negocio (símbolo y decimales configurados).
final currencyFormatProvider = Provider<CurrencyFormat>((Ref ref) {
  final CompanyProfile? profile = ref.watch(companyProfileProvider).value;
  if (profile == null) return const CurrencyFormat();
  return CurrencyFormat(
    code: profile.currencyCode,
    symbol: profile.currencySymbol,
  );
});

/// Reglas de operación vigentes (impuestos y políticas del negocio).
///
/// Se leen una vez y se mantienen en un `FutureProvider`: cambiarlas en
/// Configuración invalida el proveedor y toda la aplicación —carrito, cobro y
/// arqueo— pasa a usar los valores nuevos sin reiniciar.
class OperationSettings {
  const OperationSettings({
    required this.rateBps,
    required this.includedInPrice,
    required this.label,
    required this.allowCreditSales,
    required this.requireOpenSession,
    required this.allowNegativeStock,
  });

  static const OperationSettings defaults = OperationSettings(
    rateBps: AppConfig.defaultTaxRateBps,
    includedInPrice: AppConfig.defaultTaxIncludedInPrice,
    label: 'IVA',
    allowCreditSales: true,
    requireOpenSession: true,
    allowNegativeStock: false,
  );

  final int rateBps;
  final bool includedInPrice;
  final String label;

  /// Se permite fiar (venta a crédito a un cliente registrado).
  final bool allowCreditSales;

  /// Exige un turno de caja abierto para cobrar en efectivo.
  final bool requireOpenSession;

  /// Permite vender sin stock (se corrige después con el conteo físico).
  final bool allowNegativeStock;
}

final operationSettingsProvider = FutureProvider<OperationSettings>((Ref ref) async {
  final SettingsDao settings = ref.watch(appDatabaseProvider).settingsDao;
  final CompanyProfile? profile = await settings.companyProfile();
  return OperationSettings(
    rateBps: await settings.intValue(
      SettingsKeys.taxRateBps,
      fallback: profile?.defaultTaxRateBps ?? AppConfig.defaultTaxRateBps,
    ),
    includedInPrice: await settings.boolValue(
      SettingsKeys.taxIncluded,
      fallback: profile?.taxIncludedInPrice ?? AppConfig.defaultTaxIncludedInPrice,
    ),
    label: profile?.taxLabel ?? 'IVA',
    allowCreditSales: await settings.boolValue(
      SettingsKeys.allowCreditSales,
      fallback: true,
    ),
    requireOpenSession: await settings.boolValue(
      SettingsKeys.requireOpenSession,
      fallback: true,
    ),
    allowNegativeStock: await settings.boolValue(
      SettingsKeys.allowNegativeStock,
      fallback: false,
    ),
  );
});

/// Turno de caja abierto (null si la caja está cerrada).
final cashSessionProvider = StreamProvider<CashSession?>(
  (Ref ref) => ref.watch(appDatabaseProvider).cashDao.watchCurrentSession(),
);

/// Equipo actual (nombre, prefijo de folios) para tickets y auditoría.
final deviceProvider = FutureProvider<Device>((Ref ref) async {
  final SettingsDao dao = ref.watch(appDatabaseProvider).settingsDao;
  return (await dao.device()) ??
      dao.ensureDevice(
        deviceUuid: ref.watch(appDatabaseProvider).deviceUuid,
        name: AppConfig.defaultDeviceName,
        folioPrefix: 'A',
      );
});

/// Configuración de impresora y cajón.
final printerConfigProvider = FutureProvider<PrinterConfig>(
  (Ref ref) => PrinterConfig.load(ref.watch(appDatabaseProvider)),
);

/// Valor de configuración por clave (agrupadores booleanos y numéricos).
final settingsValueProvider = FutureProvider.family<String?, String>((Ref ref, String key) {
  return ref.watch(appDatabaseProvider).settingsDao.rawValue(key);
});

// -----------------------------------------------------------------------------
// Catálogos
// -----------------------------------------------------------------------------

/// Usuarios activos (pantalla de acceso y módulo de configuración).
final usersProvider = StreamProvider<List<User>>(
  (Ref ref) => ref.watch(appDatabaseProvider).usersDao.watchAll(),
);

/// Productos con stock por debajo del mínimo (alerta del dashboard).
final lowStockProductsProvider = StreamProvider<List<Product>>(
  (Ref ref) => ref.watch(appDatabaseProvider).productsDao.watchLowStock(),
);

/// Pedidos en espera (F4).
final heldOrdersProvider = StreamProvider<List<Sale>>(
  (Ref ref) => ref.watch(appDatabaseProvider).salesDao.watchHeldOrders(),
);

/// Categorías activas del catálogo (filtros y formularios).
final categoriesProvider = StreamProvider<List<Category>>(
  (Ref ref) => ref.watch(appDatabaseProvider).productsDao.watchCategories(),
);

final heldCountProvider = StreamProvider<int>(
  (Ref ref) => ref.watch(appDatabaseProvider).salesDao.watchHeldCount(),
);

/// Producto por código de barras (etiquetas y verificación de catálogo).
final productByBarcodeProvider = FutureProvider.family<Product?, String>(
  (Ref ref, String barcode) =>
      ref.watch(appDatabaseProvider).productsDao.findByBarcode(barcode),
);

// -----------------------------------------------------------------------------
// Utilidades de presentación
// -----------------------------------------------------------------------------
