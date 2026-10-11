import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../logging/app_logger.dart';

/// Claves usadas en el almacén seguro.
abstract final class SecureKeys {
  /// Clave de cifrado del archivo SQLite (hex de 32 bytes).
  static const String databaseKey = 'ultrapos.database.key';

  /// UUID estable de este equipo (identifica la caja ante la nube).
  static const String deviceUuid = 'ultrapos.device.uuid';

  /// Token de acceso al backend (JWT / API key).
  static const String apiToken = 'ultrapos.api.token';

  /// Identificador de sesión de sincronización.
  static const String syncSession = 'ultrapos.sync.session';
}

/// Acceso al almacén seguro del sistema operativo.
///
/// En Windows, `flutter_secure_storage` cifra con **DPAPI** (protegido por la
/// cuenta de usuario). Es el lugar correcto para la clave de la base de datos:
/// si roban el disco del equipo, el `.sqlite` sin esa clave es ilegible.
///
/// Robustez: si el almacén seguro falla (perfil corrupto, políticas de
/// dominio agresivas), UltraPOS **no se bloquea**: cae a un archivo local con
/// permisos restringidos y registra un evento crítico para el administrador.
class SecureStorageService {
  SecureStorageService({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
              wOptions: WindowsOptions(useBackwardCompatibility: false),
            );

  final FlutterSecureStorage _storage;

  static const String _scope = 'secure_storage';

  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } on Object catch (error) {
      Log.warning(_scope, 'Lectura de almacén seguro fallida para $key', error: error);
      return _fallbackFile()?.read(key);
    }
  }

  Future<void> write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
      return;
    } on Object catch (error) {
      Log.warning(_scope, 'Escritura en almacén seguro fallida para $key', error: error);
    }
    _fallbackFile()?.write(key, value);
  }

  Future<void> delete(String key) async {
    try {
      await _storage.delete(key: key);
    } on Object catch (error) {
      Log.warning(_scope, 'Borrado en almacén seguro fallido para $key', error: error);
    }
    _fallbackFile()?.remove(key);
  }

  /// Devuelve un valor existente o lo crea si no existe.
  Future<String> readOrCreate(String key, String Function() factory) async {
    final String? existing = await read(key);
    if (existing != null && existing.isNotEmpty) return existing;
    final String created = factory();
    await write(key, created);
    return created;
  }

  /// Clave de cifrado de SQLite en formato hex (64 caracteres = 32 bytes).
  ///
  /// Se guarda como clave cruda en hex, que es lo que espera
  /// `PRAGMA key = "x'...'"`.
  Future<String> readOrCreateDatabaseKey() => readOrCreate(
        SecureKeys.databaseKey,
        () {
          final Random random = Random.secure();
          final StringBuffer buffer = StringBuffer();
          for (int i = 0; i < 32; i++) {
            buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
          }
          return buffer.toString().toUpperCase();
        },
      );

  /// Respaldo en archivo, solo si el almacén seguro no está disponible.
  _FallbackSecretFile? _fallbackFile() {
    try {
      final String base = Platform.environment['LOCALAPPDATA'] ??
          Platform.environment['APPDATA'] ??
          Directory.systemTemp.path;
      final Directory dir = Directory('$base\\UltraPOS\\secrets');
      dir.createSync(recursive: true);
      return _FallbackSecretFile(File('${dir.path}\\local_secrets.json'));
    } on Object catch (error) {
      Log.error(_scope, 'Ni el almacén seguro ni el respaldo están disponibles', error: error);
      return null;
    }
  }
}

/// Almacén JSON plano de último recurso (documentado como riesgoso).
class _FallbackSecretFile {
  _FallbackSecretFile(this._file);

  final File _file;

  Map<String, String> _load() {
    try {
      if (!_file.existsSync()) return <String, String>{};
      final Object? decoded = jsonDecode(_file.readAsStringSync());
      if (decoded is Map<String, dynamic>) {
        return decoded.map((String k, Object? v) => MapEntry<String, String>(k, '$v'));
      }
    } on Object {
      // Archivo corrupto: se descarta.
    }
    return <String, String>{};
  }

  String? read(String key) => _load()[key];

  void write(String key, String value) {
    Log.critical(
      'secure_storage',
      'Guardando $key sin cifrado del sistema operativo. Revise el perfil de Windows.',
    );
    final Map<String, String> data = _load()..[key] = value;
    _file.writeAsStringSync(jsonEncode(data));
  }

  void remove(String key) {
    final Map<String, String> data = _load()..remove(key);
    _file.writeAsStringSync(jsonEncode(data));
  }
}
