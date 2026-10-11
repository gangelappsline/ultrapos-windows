import 'package:drift/drift.dart';

import '../../config/app_config.dart';
import '../../domain/enums.dart';
import '../app_database.dart';
import '../tables/system_tables.dart';

part 'settings_dao.g.dart';

/// Claves de configuración conocidas.
///
/// Se centralizan aquí para que un cambio de nombre no provoque que la
/// configuración se "pierda" silenciosamente en las cajas ya instaladas.
abstract final class SettingsKeys {
  // --- Negocio ---
  static const String businessName = 'business.name';
  static const String businessTaxId = 'business.tax_id';
  static const String businessAddress = 'business.address';
  static const String businessPhone = 'business.phone';

  // --- Impuestos y moneda ---
  static const String taxRateBps = 'tax.rate_bps';
  static const String taxIncluded = 'tax.included_in_price';
  static const String defaultDiscountBps = 'sales.default_discount_bps';

  // --- Operación ---
  static const String requireOpenSession = 'sales.require_cash_session';
  static const String allowNegativeStock = 'inventory.allow_negative_stock';
  static const String allowCreditSales = 'sales.allow_credit';
  static const String printAutomatically = 'printer.auto_print';
  static const String printCopies = 'printer.copies';
  static const String openDrawerOnCash = 'drawer.open_on_cash_payment';

  // --- Hardware ---
  static const String printerType = 'printer.type';
  static const String printerName = 'printer.windows_name';
  static const String printerHost = 'printer.network_host';
  static const String printerPort = 'printer.network_port';
  static const String printerComPort = 'printer.com_port';
  static const String printerComBaud = 'printer.com_baud';
  static const String printerPaperWidth = 'printer.paper_width_mm';
  static const String printerCharset = 'printer.charset';
  static const String drawerType = 'drawer.type';
  static const String scannerEnabled = 'scanner.enabled';
  static const String scannerPrefix = 'scanner.prefix';
  static const String scannerSuffix = 'scanner.suffix';

  // --- Sincronización ---
  static const String syncEnabled = 'sync.enabled';
  static const String syncIntervalSeconds = 'sync.interval_seconds';
  static const String syncLastSuccessAt = 'sync.last_success_at';
  static const String syncAutoPull = 'sync.auto_pull';
  static const String syncWifiOnly = 'sync.wifi_only';

  // --- Interfaz ---
  static const String themeDensity = 'ui.density';
  static const String rememberWindowBounds = 'ui.remember_window_bounds';
  static const String windowBounds = 'ui.window_bounds';
  static const String showShortcutHints = 'ui.show_shortcut_hints';

  // --- Licencia / soporte ---
  static const String licenseKey = 'license.key';
  static const String supportContact = 'support.contact';
}

/// Acceso a configuración clave-valor, perfil de empresa y dispositivo.
@DriftAccessor(tables: <Type>[AppSettings, CompanyProfiles, Devices, DocumentSequences])
class SettingsDao extends DatabaseAccessor<AppDatabase>
    with _$SettingsDaoMixin {
  SettingsDao(AppDatabase db) : super(db);

  // ---------------------------------------------------------------------------
  // Clave-valor
  // ---------------------------------------------------------------------------

  Future<String?> rawValue(String key) async {
    final AppSetting? row =
        await (select(appSettings)..where((t) => t.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<String> stringValue(String key, {String fallback = ''}) async =>
      await rawValue(key) ?? fallback;

  Future<bool> boolValue(String key, {bool fallback = false}) async {
    final String? raw = await rawValue(key);
    if (raw == null) return fallback;
    return raw == 'true' || raw == '1';
  }

  Future<int> intValue(String key, {int fallback = 0}) async {
    final String? raw = await rawValue(key);
    return raw == null ? fallback : (int.tryParse(raw) ?? fallback);
  }

  Future<double> doubleValue(String key, {double fallback = 0}) async {
    final String? raw = await rawValue(key);
    return raw == null ? fallback : (double.tryParse(raw) ?? fallback);
  }

  /// Escribe un valor configurando su tipo (para poder leerlo sin ambigüedad).
  Future<void> setValue(
    String key,
    Object? value, {
    bool syncToCloud = true,
    SyncOperation operation = SyncOperation.update,
  }) async {
    final DateTime now = attachedDatabase.now;
    final String type = _typeOf(value);
    final String encoded = _encode(value);

    await attachedDatabase.writeWithOutbox(
      action: () => into(appSettings).insertOnConflictUpdate(
        AppSettingsCompanion.insert(
          key: key,
          value: encoded,
          valueType: Value<String>(type),
          syncToCloud: Value<bool>(syncToCloud),
          updatedAt: now,
        ),
      ),
      entity: SyncEntity.setting,
      entityUuid: key,
      operation: operation,
      payload: <String, Object?>{
        'key': key,
        'value': encoded,
        'value_type': type,
        'updated_at': now.toUtc().toIso8601String(),
      },
      lwwTimestamp: now,
      priority: 60,
    );
  }

  Stream<AppSetting?> watchValue(String key) =>
      (select(appSettings)..where((t) => t.key.equals(key))).watchSingleOrNull();

  /// Escribe el valor solo si la clave aún no existe (valores por defecto).
  Future<void> setIfAbsent(String key, Object? value, {bool syncToCloud = false}) async {
    final String? existing = await rawValue(key);
    if (existing != null) return;
    await setValue(key, value, syncToCloud: syncToCloud, operation: SyncOperation.insert);
  }

  /// Todas las claves (pantalla de diagnóstico).
  Future<Map<String, String>> allValues() async {
    final List<AppSetting> rows = await select(appSettings).get();
    return <String, String>{
      for (final AppSetting row in rows) row.key: row.value,
    };
  }

  Future<void> deleteValue(String key) async {
    await (delete(appSettings)..where((t) => t.key.equals(key))).go();
  }

  // ---------------------------------------------------------------------------
  // Perfil de empresa (fila única)
  // ---------------------------------------------------------------------------

  Stream<CompanyProfile?> watchCompanyProfile() =>
      (select(companyProfiles)..where((t) => t.id.equals(1))).watchSingleOrNull();

  Future<CompanyProfile?> companyProfile() =>
      (select(companyProfiles)..where((t) => t.id.equals(1))).getSingleOrNull();

  /// Devuelve el perfil de empresa, creándolo con valores por defecto la
  /// primera vez que se ejecuta la aplicación en un equipo nuevo.
  Future<CompanyProfile> ensureCompanyProfile({String? legalName}) async {
    final CompanyProfile? existing = await companyProfile();
    if (existing != null) return existing;

    final DateTime now = attachedDatabase.now;
    await into(companyProfiles).insert(
      CompanyProfilesCompanion.insert(
        id: 1,
        legalName: (legalName == null || legalName.trim().isEmpty)
            ? 'Mi Negocio'
            : legalName.trim(),
        taxId: const Value<String>(''),
        currencyCode: const Value<String>(AppConfig.defaultCurrencyCode),
        currencySymbol: const Value<String>(AppConfig.defaultCurrencySymbol),
        defaultTaxRateBps: const Value<int>(AppConfig.defaultTaxRateBps),
        taxIncludedInPrice: const Value<bool>(AppConfig.defaultTaxIncludedInPrice),
        updatedAt: now,
      ),
    );
    return (await companyProfile())!;
  }

  Future<void> saveCompanyProfile(CompanyProfilesCompanion changes) async {
    final DateTime now = attachedDatabase.now;
    await attachedDatabase.writeWithOutbox(
      action: () async {
        final CompanyProfile? current = await companyProfile();
        if (current == null) {
          await into(companyProfiles).insert(changes.copyWith(updatedAt: Value<DateTime>(now)));
        } else {
          await (update(companyProfiles)..where((t) => t.id.equals(1)))
              .write(changes.copyWith(updatedAt: Value<DateTime>(now)));
        }
        await attachedDatabase.recordAudit(
          entity: 'company',
          action: 'update',
          note: 'Actualización de datos fiscales/del negocio',
        );
      },
      entity: SyncEntity.company,
      entityUuid: 'company',
      operation: SyncOperation.update,
      payload: <String, Object?>{'updated_at': now.toUtc().toIso8601String()},
      lwwTimestamp: now,
      priority: 30,
    );
  }

  // ---------------------------------------------------------------------------
  // Dispositivo
  // ---------------------------------------------------------------------------

  Future<Device?> device() =>
      (select(devices)..where((t) => t.id.equals(1))).getSingleOrNull();

  /// Asegura la fila del dispositivo; crea la secuencia de folios si falta.
  Future<Device> ensureDevice({
    required String deviceUuid,
    required String name,
    required String folioPrefix,
    String? hostname,
    String? appVersion,
  }) async {
    final Device? existing = await device();
    final DateTime now = attachedDatabase.now;
    if (existing != null) {
      await (update(devices)..where((t) => t.id.equals(1))).write(
        DevicesCompanion(
          name: Value<String>(name),
          hostname: hostname == null ? const Value.absent() : Value<String?>(hostname),
          appVersion: Value<String?>(appVersion),
          lastSeenAt: Value<DateTime>(now),
        ),
      );
      return (await device())!;
    }

    await into(devices).insert(
      DevicesCompanion.insert(
        id: 1,
        uuid: deviceUuid,
        name: name,
        folioPrefix: folioPrefix,
        hostname: Value<String?>(hostname),
        appVersion: Value<String?>(appVersion),
        createdAt: now,
        lastSeenAt: now,
      ),
    );
    await setIfAbsent('device.folio_prefix', folioPrefix, syncToCloud: false);
    return (await device())!;
  }

  Future<void> updateDeviceName(String name, {String? folioPrefix}) async {
    await (update(devices)..where((t) => t.id.equals(1))).write(
      DevicesCompanion(
        name: Value<String>(name),
        folioPrefix: folioPrefix == null ? const Value.absent() : Value<String>(folioPrefix),
      ),
    );
  }

  /// Reserva y devuelve el siguiente número de folio de forma **atómica**.
  ///
  /// El `UPDATE ... RETURNING` garantiza que dos ventas simultáneas (o dos
  /// hilos, o un reinicio justo en el momento) jamás obtengan el mismo folio.
  /// Nunca se genera un folio en memoria.
  Future<int> nextFolioNumber(String prefix) async {
    await customStatement(
      '''
      INSERT INTO document_sequences (prefix, last_number, updated_at)
      VALUES (?, 0, ?)
      ON CONFLICT(prefix) DO NOTHING;
      ''',
      <Object?>[prefix, attachedDatabase.now.toUtc().millisecondsSinceEpoch],
    );

    final QueryRow row = await customSelect(
      '''
      UPDATE document_sequences
         SET last_number = last_number + 1,
             updated_at  = ?
       WHERE prefix = ?
      RETURNING last_number;
      ''',
      variables: <Variable<Object>>[
        Variable.withInt(attachedDatabase.now.toUtc().millisecondsSinceEpoch),
        Variable.withString(prefix),
      ],
    ).getSingle();

    return row.read<int>('last_number');
  }

  // ---------------------------------------------------------------------------
  // Utilidades privadas
  // ---------------------------------------------------------------------------

  String _typeOf(Object? value) => switch (value) {
        null => 'null',
        bool() => 'bool',
        int() => 'int',
        double() => 'double',
        String() => 'string',
        _ => 'json',
      };

  String _encode(Object? value) => switch (value) {
        null => '',
        bool() => value ? 'true' : 'false',
        _ => '$value',
      };
}
