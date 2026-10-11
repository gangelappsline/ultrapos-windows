import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../config/app_config.dart';

/// Nivel de severidad del log.
enum LogLevel {
  debug(0, 'DEBUG'),
  info(1, 'INFO'),
  warning(2, 'WARN'),
  error(3, 'ERROR'),
  critical(4, 'CRITICAL');

  const LogLevel(this.severity, this.label);

  final int severity;
  final String label;
}

/// Registro de un evento de log.
@immutable
class LogRecord {
  const LogRecord({
    required this.timestamp,
    required this.level,
    required this.scope,
    required this.message,
    this.error,
    this.stackTrace,
    this.data = const <String, Object?>{},
  });

  final DateTime timestamp;
  final LogLevel level;

  /// Módulo emisor: `sync`, `sales`, `hardware`, `db`...
  final String scope;
  final String message;
  final Object? error;
  final StackTrace? stackTrace;
  final Map<String, Object?> data;

  String format() {
    final StringBuffer buffer = StringBuffer()
      ..write('[${timestamp.toIso8601String()}] ')
      ..write('[${level.label.padRight(8)}] ')
      ..write('[$scope] ')
      ..write(message);
    if (data.isNotEmpty) {
      buffer.write(' | ${data.entries.map((MapEntry<String, Object?> e) => '${e.key}=${e.value}').join(' ')}');
    }
    if (error != null) buffer.write('\n  -> $error');
    if (stackTrace != null && level.severity >= LogLevel.error.severity) {
      buffer.write('\n$stackTrace');
    }
    return buffer.toString();
  }

  @override
  String toString() => format();
}

/// Logger de UltraPOS sin dependencias externas.
///
/// * Mantiene un **buffer circular en memoria** (alimenta el visor de
///   "Diagnóstico" de la pantalla de Configuración sin tocar el disco).
/// * Opcionalmente escribe a un archivo rotativo en
///   `%LOCALAPPDATA%\UltraPOS\logs`, imprescindible para dar soporte
///   en cajas que ya están en producción (el cajero no nos manda la consola).
/// * Es asíncrono por diseño: un POS **jamás** debe bloquear la venta
///   porque el disco esté lento.
class AppLogger {
  AppLogger._();

  static final AppLogger instance = AppLogger._();

  /// Máximo de registros en memoria.
  static const int _ringBufferSize = 1200;

  /// Tamaño máximo de un archivo de log antes de rotar (2 MB).
  static const int _maxFileBytes = 2 * 1024 * 1024;

  /// Archivos rotados que se conservan.
  static const int _maxRotatedFiles = 5;

  final Queue<LogRecord> _buffer = Queue<LogRecord>();
  final StreamController<LogRecord> _controller =
      StreamController<LogRecord>.broadcast();

  IOSink? _sink;
  File? _file;
  int _bytesWritten = 0;
  bool _initialized = false;
  LogLevel minLevel = AppConfig.verboseLogging ? LogLevel.debug : LogLevel.info;

  /// Registros recientes (más nuevo al final).
  List<LogRecord> get records => List<LogRecord>.unmodifiable(_buffer);

  /// Flujo en vivo para el panel de diagnóstico.
  Stream<LogRecord> get stream => _controller.stream;

  /// Prepara el archivo de log. Idempotente y tolerante a fallos:
  /// si no se puede escribir, la app sigue funcionando solo en memoria.
  Future<void> initialize({required Directory logDirectory}) async {
    if (_initialized) return;
    _initialized = true;
    try {
      await logDirectory.create(recursive: true);
      _file = File('${logDirectory.path}${Platform.pathSeparator}ultrapos.log');
      await _rotateIfNeeded(_file!);
      _bytesWritten = await _file!.exists() ? await _file!.length() : 0;
      _sink = _file!.openWrite(mode: FileMode.append, encoding: const SystemEncoding());
    } on Object catch (error) {
      // No se puede loggear el fallo del logger sin romper la app.
      _emit(LogRecord(
        timestamp: DateTime.now(),
        level: LogLevel.warning,
        scope: 'logger',
        message: 'No se pudo abrir el archivo de log; usando solo memoria',
        error: error,
      ));
    }
  }

  void debug(String scope, String message, {Map<String, Object?> data = const {}}) =>
      _log(LogLevel.debug, scope, message, data: data);

  void info(String scope, String message, {Map<String, Object?> data = const {}}) =>
      _log(LogLevel.info, scope, message, data: data);

  void warning(
    String scope,
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?> data = const {},
  }) =>
      _log(LogLevel.warning, scope, message, error: error, stackTrace: stackTrace, data: data);

  void error(
    String scope,
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?> data = const {},
  }) =>
      _log(LogLevel.error, scope, message, error: error, stackTrace: stackTrace, data: data);

  void critical(
    String scope,
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?> data = const {},
  }) =>
      _log(LogLevel.critical, scope, message, error: error, stackTrace: stackTrace, data: data);

  /// Registra y **reporta** una excepción no controlada desde Flutter.
  void captureFlutterError(FlutterErrorDetails details) => critical(
        'flutter',
        details.exceptionAsString(),
        error: details.exception,
        stackTrace: details.stack,
        data: <String, Object?>{'library': details.library ?? 'desconocida'},
      );

  /// Registra excepciones de zona no capturadas (async sin await).
  void captureUncaught(Object error, StackTrace stack) =>
      critical('zone', 'Excepción no capturada en zona asíncrona', error: error, stackTrace: stack);

  void _log(
    LogLevel level,
    String scope,
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?> data = const {},
  }) {
    if (level.severity < minLevel.severity) return;
    _emit(LogRecord(
      timestamp: DateTime.now(),
      level: level,
      scope: scope,
      message: message,
      error: error,
      stackTrace: stackTrace,
      data: data,
    ));
  }

  void _emit(LogRecord record) {
    _buffer.addLast(record);
    while (_buffer.length > _ringBufferSize) {
      _buffer.removeFirst();
    }
    if (!_controller.isClosed) {
      _controller.add(record);
    }
    // Solo se escribe a disco a partir de INFO: el DEBUG en caliente
    // de un buscador puede generar decenas de líneas por segundo.
    if (record.level.severity >= LogLevel.info.severity) {
      unawaited(_writeToDisk(record));
    }
    if (kDebugMode) {
      // ignore: avoid_print
      print(record.format());
    }
  }

  Future<void> _writeToDisk(LogRecord record) async {
    final IOSink? sink = _sink;
    final File? file = _file;
    if (sink == null || file == null) return;
    try {
      final String line = '${record.format()}\n';
      sink.write(line);
      await sink.flush();
      _bytesWritten += line.length;
      if (_bytesWritten >= _maxFileBytes) {
        await _rotate(file);
      }
    } on Object {
      // El log nunca debe tumbar la aplicación.
    }
  }

  Future<void> _rotate(File file) async {
    try {
      await _sink?.flush();
      await _sink?.close();
      _sink = null;
      for (int i = _maxRotatedFiles - 1; i >= 1; i--) {
        final File older = File('${file.path}.$i');
        if (await older.exists()) {
          await older.rename('${file.path}.${i + 1}');
        }
      }
      if (await file.exists()) {
        await file.rename('${file.path}.1');
      }
      _sink = file.openWrite(mode: FileMode.write, encoding: const SystemEncoding());
      _bytesWritten = 0;
    } on Object {
      // Si la rotación falla, se sigue escribiendo en el archivo actual.
    }
  }

  Future<void> _rotateIfNeeded(File file) async {
    if (!await file.exists()) return;
    final int length = await file.length();
    if (length >= _maxFileBytes) {
      await _rotate(file);
    }
  }

  /// Exporta el buffer en memoria (para el botón "Exportar diagnóstico").
  String exportBuffer() => _buffer.map((LogRecord r) => r.format()).join('\n');

  /// Ruta del archivo de log activo, si existe.
  String? get logFilePath => _file?.path;

  Future<void> dispose() async {
    await _sink?.flush();
    await _sink?.close();
    await _controller.close();
  }
}

/// Acceso corto: `Log.sync('mensaje')`.
abstract final class Log {
  static AppLogger get instance => AppLogger.instance;

  static void debug(String scope, String message, {Map<String, Object?> data = const {}}) =>
      AppLogger.instance.debug(scope, message, data: data);

  static void info(String scope, String message, {Map<String, Object?> data = const {}}) =>
      AppLogger.instance.info(scope, message, data: data);

  static void warning(
    String scope,
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?> data = const {},
  }) =>
      AppLogger.instance.warning(scope, message, error: error, stackTrace: stackTrace, data: data);

  static void error(
    String scope,
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?> data = const {},
  }) =>
      AppLogger.instance.error(scope, message, error: error, stackTrace: stackTrace, data: data);

  static void critical(
    String scope,
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?> data = const {},
  }) =>
      AppLogger.instance.critical(scope, message, error: error, stackTrace: stackTrace, data: data);
}
