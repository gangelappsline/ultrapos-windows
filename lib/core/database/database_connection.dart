import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;

import '../config/app_config.dart';
import '../errors/app_failure.dart';
import '../logging/app_logger.dart';
import '../security/secure_storage_service.dart';

/// Apertura y configuración de la base de datos local.
///
/// Decisiones críticas para Windows:
///
/// 1. **Se abre en un isolate de fondo** (`NativeDatabase.createInBackground`).
///    En un POS, la UI no puede permitirse ni un "micro-corte" mientras SQLite
///    hace un checkpoint de WAL de 200 MB. El cajero sigue tecleando.
///
/// 2. **WAL + synchronous=NORMAL**: el estándar de oro para escritorio.
///    `journal_mode = WAL` permite leer mientras se escribe y sobrevive a un
///    apagado brusco del equipo (nada raro en un mostrador). `synchronous`
///    NORMAL evita un `fsync` por transacción (de ~40 ms a ~1 ms), con una
///    pérdida teórica máxima de la última transacción ante corte de energía.
///    Para un POS que imprimió el ticket, la venta ya está en disco: el
///    compromiso es correcto.
///
/// 3. **`busy_timeout`** alto: si el antivirus o un respaldo bloquean el
///    archivo un instante, la venta espera en lugar de fallar con SQLITE_BUSY.
///
/// 4. **Cifrado SQLCipher opcional** (fail-closed): si se habilita pero la
///    librería cargada no es SQLCipher, la app **no arranca** en lugar de
///    escribir datos sensibles en claro. Ver docs/WINDOWS_SETUP.md.
class DatabaseConnection {
  DatabaseConnection({required this.secureStorage, this.overrideFile});

  final SecureStorageService secureStorage;

  /// Ruta explícita (tests y herramientas de mantenimiento).
  final File? overrideFile;

  /// Carpeta de datos de UltraPOS en `%LOCALAPPDATA%`.
  static Directory defaultDataDirectory() {
    final String base = Platform.environment['LOCALAPPDATA'] ??
        Platform.environment['APPDATA'] ??
        Directory.systemTemp.path;
    return Directory(p.join(base, AppConfig.appName, 'data'));
  }

  /// Carpeta de respaldos locales.
  static Directory defaultBackupDirectory() {
    final String base = Platform.environment['LOCALAPPDATA'] ??
        Platform.environment['APPDATA'] ??
        Directory.systemTemp.path;
    return Directory(p.join(base, AppConfig.appName, 'backups'));
  }

  /// Carpeta de logs.
  static Directory defaultLogDirectory() {
    final String base = Platform.environment['LOCALAPPDATA'] ??
        Platform.environment['APPDATA'] ??
        Directory.systemTemp.path;
    return Directory(p.join(base, AppConfig.appName, 'logs'));
  }

  /// Archivo principal de la base de datos.
  File resolveDatabaseFile() {
    if (overrideFile != null) return overrideFile!;
    return File(
      p.join(defaultDataDirectory().path, '${AppConfig.databaseName}.sqlite'),
    );
  }

  /// Construye el ejecutor de consultas listo para Drift.
  QueryExecutor build() {
    return LazyDatabase(() async {
      final File file = resolveDatabaseFile();
      await file.parent.create(recursive: true);

      final String? encryptionKey = AppConfig.databaseEncryptionEnabled
          ? await secureStorage.readOrCreateDatabaseKey()
          : null;

      Log.info(
        'db',
        'Abriendo base de datos local',
        data: <String, Object?>{
          'path': file.path,
          'encrypted': encryptionKey != null,
          'appVersion': AppConfig.appVersion,
        },
      );

      return NativeDatabase.createInBackground(
        file,
        logStatements: AppConfig.logSqlStatements,
        setup: (RawDatabase db) {
          _applyPragmas(db);
          if (encryptionKey != null) {
            _applyEncryption(db, encryptionKey);
          }
        },
      );
    });
  }

  /// PRAGMAs de rendimiento y seguridad.
  void _applyPragmas(RawDatabase db) {
    db.execute('PRAGMA foreign_keys = ON;');
    db.execute('PRAGMA journal_mode = WAL;');
    db.execute('PRAGMA synchronous = NORMAL;');
    db.execute('PRAGMA busy_timeout = 15000;');
    db.execute('PRAGMA temp_store = MEMORY;');
    // ~64 MB de caché: suficiente para un catálogo de decenas de miles de SKUs.
    db.execute('PRAGMA cache_size = -64000;');
    // Recolecta espacio tras operaciones grandes sin bloquear permanentemente.
    db.execute('PRAGMA auto_vacuum = INCREMENTAL;');
    db.execute('PRAGMA wal_autocheckpoint = 1000;');
  }

  /// Aplica la clave de cifrado y **verifica** que SQLCipher esté realmente
  /// presente. Sin esta verificación, un despliegue mal configurado dejaría la
  /// base de datos de ventas en texto plano sin que nadie lo note.
  void _applyEncryption(RawDatabase db, String hexKey) {
    db.execute("PRAGMA key = \"x'$hexKey'\";");
    db.execute('PRAGMA cipher_memory_security = ON;');
    db.execute('PRAGMA kdf_iter = 256000;');

    final ResultSet version = db.select('PRAGMA cipher_version;');
    final String cipherVersion =
        version.isEmpty || version.first.data.isEmpty ? '' : '${version.first.data.values.first ?? ''}';

    if (cipherVersion.trim().isEmpty) {
      throw const DatabaseFailure(
        message: 'La base de datos cifrada no pudo inicializarse.',
        technicalDetail:
            'ULTRAPOS_DB_ENCRYPTION=true pero la librería cargada no es SQLCipher. '
            'Agregue sqlcipher_flutter_libs y quite sqlite3_flutter_libs '
            '(ver docs/WINDOWS_SETUP.md).',
      );
    }

    Log.info('db', 'SQLCipher activo', data: <String, Object?>{'cipher': cipherVersion.trim()});
  }

  /// Integridad referencial y de páginas: se ejecuta al abrir (barato) y
  /// permite detectar a tiempo un disco muriendo o un archivo corrupto.
  Future<void> integrityCheck(RawDatabase db) async {
    final ResultSet result = db.select('PRAGMA integrity_check;');
    final String outcome =
        result.isEmpty ? 'desconocido' : '${result.first.data.values.first}';
    if (outcome.toLowerCase() != 'ok') {
      Log.critical(
        'db',
        'integrity_check reportó problemas',
        data: <String, Object?>{'result': outcome},
      );
    } else {
      Log.debug('db', 'integrity_check OK');
    }
  }
}
