import 'package:drift/drift.dart';

import '../converters/app_converters.dart';
import '../../domain/enums.dart';

/// Tablas de sistema: usuarios, configuración, empresa, auditoría y
/// secuencias de folios.
library;

/// Usuarios del sistema (cajeros, supervisores, administradores).
///
/// El PIN nunca se guarda en claro: se almacena PBKDF2-HMAC-SHA256 con sal
/// aleatoria de 16 bytes y 120.000 iteraciones (ver `core/security/pin_hasher`).
/// Un POS vive en un mostrador: asumimos que el equipo puede ser inspeccionado.
@TableIndex(name: 'idx_users_username', columns: {#username}, unique: true)
@TableIndex(name: 'idx_users_uuid', columns: {#uuid}, unique: true)
@DataClassName('User')
class Users extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// Identidad global (clave de sincronización entre cajas y nube).
  TextColumn get uuid => text().withLength(min: 8, max: 64)();

  TextColumn get username => text().withLength(min: 2, max: 40)();

  TextColumn get fullName => text().withLength(min: 2, max: 120)();

  TextColumn get role => text().map(const UserRoleConverter())();

  /// Hash PBKDF2 en base64 (`null` si el usuario se autentica por otro medio).
  TextColumn get pinHash => text().nullable()();

  /// Sal del PIN en base64.
  TextColumn get pinSalt => text().nullable()();

  /// Identificador visible en el ticket ("Atendido por: María #04").
  TextColumn get employeeCode => text().nullable()();

  BoolColumn get isActive => boolean().withDefault(const Constant(true))();

  /// Descuento máximo que puede autorizar sin supervisor (basis points).
  IntColumn get maxDiscountBps => integer().withDefault(const Constant(0))();

  DateTimeColumn get lastLoginAt =>
      integer().map(const NullableDateTimeMillisConverter()).nullable()();

  // --- Metadatos de sincronización ---
  DateTimeColumn get createdAt => integer().map(const DateTimeMillisConverter())();
  DateTimeColumn get updatedAt => integer().map(const DateTimeMillisConverter())();
  DateTimeColumn get deletedAt =>
      integer().map(const NullableDateTimeMillisConverter()).nullable()();
  IntColumn get syncVersion => integer().withDefault(const Constant(1))();
  TextColumn get deviceId => text().nullable()();
}

/// Configuración clave-valor.
///
/// Se usa una tabla KV (y no columnas) porque la configuración de un POS crece
/// de forma impredecible (impresora, cajón, atajos, sync...) y cada migración
/// de esquema en producción cuesta una actualización en cada caja.
@TableIndex(name: 'idx_settings_key', columns: {#key}, unique: true)
@DataClassName('AppSetting')
class AppSettings extends Table {
  /// Clave jerárquica: `printer.paper_width`, `sync.interval_seconds`.
  TextColumn get key => text().withLength(min: 2, max: 80)();

  TextColumn get value => text()();

  /// `string` | `int` | `bool` | `double` | `json`
  TextColumn get valueType => text().withDefault(const Constant('string'))();

  BoolColumn get syncToCloud => boolean().withDefault(const Constant(true))();

  DateTimeColumn get updatedAt => integer().map(const DateTimeMillisConverter())();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{key};
}

/// Datos fiscales y visuales del negocio (fila única, `id = 1`).
@DataClassName('CompanyProfile')
class CompanyProfiles extends Table {
  IntColumn get id => integer()();

  TextColumn get legalName => text().withLength(min: 1, max: 160)();

  /// NIT / RUC / RFC / CUIT.
  TextColumn get taxId => text().withDefault(const Constant(''))();

  TextColumn get address => text().withDefault(const Constant(''))();

  TextColumn get phone => text().withDefault(const Constant(''))();

  TextColumn get email => text().withDefault(const Constant(''))();

  /// Ruta local del logo (PNG/JPG) para el ticket.
  TextColumn get logoPath => text().nullable()();

  TextColumn get currencyCode => text().withDefault(const Constant('NIO'))();

  TextColumn get currencySymbol => text().withDefault(const Constant(r'C$'))();

  /// Impuesto por defecto en basis points (1600 = 16%).
  IntColumn get defaultTaxRateBps => integer().withDefault(const Constant(1600))();

  /// Si el precio de venta ya incluye impuestos (práctica habitual en LatAm).
  BoolColumn get taxIncludedInPrice =>
      boolean().withDefault(const Constant(true))();

  TextColumn get taxLabel => text().withDefault(const Constant('IVA'))();

  TextColumn get receiptHeader => text().withDefault(const Constant(''))();

  TextColumn get receiptFooter => text().withDefault(
        const Constant('¡Gracias por su compra!'),
      )();

  TextColumn get timezone => text().withDefault(const Constant('America/Managua'))();

  DateTimeColumn get updatedAt => integer().map(const DateTimeMillisConverter())();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// Secuencias de folios por prefijo y por dispositivo.
///
/// Cada caja emite folios con su propio prefijo (`A-000001`, `B-000001`) para
/// que dos terminales offline puedan vender simultáneamente sin colisionar.
@DataClassName('DocumentSequence')
class DocumentSequences extends Table {
  /// Ej: `A` (prefijo del dispositivo).
  TextColumn get prefix => text().withLength(min: 1, max: 8)();

  /// Último número emitido.
  IntColumn get lastNumber => integer().withDefault(const Constant(0))();

  DateTimeColumn get updatedAt => integer().map(const DateTimeMillisConverter())();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{prefix};
}

/// Bitácora de auditoría: quién hizo qué y cuándo.
///
/// Necesaria para anulaciones, cambios de precio, ajustes de inventario y
/// arqueos. En un POS, "no sé quién lo cambió" no es una respuesta aceptable.
@TableIndex(name: 'idx_audit_entity', columns: {#entity, #entityUuid})
@TableIndex(name: 'idx_audit_created', columns: {#createdAt})
@DataClassName('AuditLog')
class AuditLogs extends Table {
  IntColumn get id => integer().autoIncrement()();

  TextColumn get uuid => text().withLength(min: 8, max: 64)();

  /// Entidad afectada: `sale`, `product`, `cash_session`...
  TextColumn get entity => text().withLength(min: 2, max: 40)();

  TextColumn get entityUuid => text().nullable()();

  /// Acción: `create`, `update`, `void`, `login`, `open`, `close`...
  TextColumn get action => text().withLength(min: 2, max: 40)();

  TextColumn get userId => text().nullable()();

  TextColumn get userName => text().nullable()();

  /// Estado previo en JSON (para reconstruir lo que se cambió).
  TextColumn get beforeJson => text().nullable()();

  /// Estado posterior en JSON.
  TextColumn get afterJson => text().nullable()();

  TextColumn get note => text().nullable()();

  DateTimeColumn get createdAt => integer().map(const DateTimeMillisConverter())();
}

/// Estado del dispositivo (equipo Windows) que ejecuta esta instalación.
///
/// Fila única. Guarda el identificador de la caja, su prefijo de folios y la
/// información de licencia/turno activo.
@DataClassName('Device')
class Devices extends Table {
  IntColumn get id => integer()();

  /// UUID estable generado en el primer arranque y guardado en DPAPI.
  TextColumn get uuid => text().withLength(min: 8, max: 64)();

  /// Nombre legible: `CAJA-1`, `MOSTRADOR-BARRA`.
  TextColumn get name => text().withLength(min: 1, max: 60)();

  /// Prefijo de folios de este equipo.
  TextColumn get folioPrefix => text().withLength(min: 1, max: 8)();

  /// Nombre del host Windows (útil para soporte remoto).
  TextColumn get hostname => text().nullable()();

  TextColumn get appVersion => text().nullable()();

  DateTimeColumn get createdAt => integer().map(const DateTimeMillisConverter())();

  DateTimeColumn get lastSeenAt => integer().map(const DateTimeMillisConverter())();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}
