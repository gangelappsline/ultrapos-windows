import 'package:flutter/foundation.dart';

/// Jerarquía de fallos de UltraPOS.
///
/// Regla de oro del POS: **toda operación de venta es atómica y nunca falla en
/// silencio**. Cada fallo lleva un mensaje apto para mostrar al cajero (español,
/// sin jerga técnica) y un `technicalDetail` para el log.
@immutable
sealed class AppFailure implements Exception {
  const AppFailure({
    required this.message,
    this.technicalDetail,
    this.cause,
    this.stackTrace,
  });

  /// Mensaje listo para mostrar en pantalla al cajero.
  final String message;

  /// Detalle técnico para diagnóstico (nunca visible en pantalla).
  final String? technicalDetail;

  final Object? cause;
  final StackTrace? stackTrace;

  /// Código estable para telemetría/soporte.
  String get code;

  /// ¿El usuario puede resolverlo reintentando?
  bool get isRecoverable;

  @override
  String toString() =>
      '[$code] $message${technicalDetail == null ? '' : ' ($technicalDetail)'}';
}

/// Error de validación de datos de entrada (formularios, carrito).
final class ValidationFailure extends AppFailure {
  const ValidationFailure({
    required super.message,
    this.fieldErrors = const <String, String>{},
    super.technicalDetail,
  });

  /// Errores por campo, para pintarlos directamente en el formulario.
  final Map<String, String> fieldErrors;

  @override
  String get code => 'VALIDATION';

  @override
  bool get isRecoverable => true;
}

/// Error de persistencia (Drift/SQLite).
final class DatabaseFailure extends AppFailure {
  const DatabaseFailure({
    super.message = 'No se pudo guardar la información en la base de datos local.',
    super.technicalDetail,
    super.cause,
    super.stackTrace,
  });

  @override
  String get code => 'DATABASE';

  @override
  bool get isRecoverable => true;
}

/// Error de hardware: impresora, cajón, lector.
final class HardwareFailure extends AppFailure {
  const HardwareFailure({
    required super.message,
    this.device,
    super.technicalDetail,
    super.cause,
    super.stackTrace,
  });

  /// Dispositivo afectado: `printer`, `cash_drawer`, `scanner`.
  final String? device;

  @override
  String get code => 'HARDWARE';

  /// Un fallo de impresora NUNCA debe impedir cobrar: la venta ya está
  /// guardada localmente y se puede reimprimir. Por eso es recuperable.
  @override
  bool get isRecoverable => true;
}

/// Error de sincronización con la nube.
final class SyncFailure extends AppFailure {
  const SyncFailure({
    required super.message,
    this.retryable = true,
    this.httpStatus,
    super.technicalDetail,
    super.cause,
    super.stackTrace,
  });

  /// Si es `false`, la operación queda en estado `failed` y requiere
  /// intervención del administrador (no se reintenta infinitamente).
  final bool retryable;
  final int? httpStatus;

  @override
  String get code => 'SYNC';

  @override
  bool get isRecoverable => retryable;
}

/// Error de autenticación / permisos.
final class AuthFailure extends AppFailure {
  const AuthFailure({
    super.message = 'Usuario o PIN incorrecto.',
    this.requiredRole,
    super.technicalDetail,
  });

  /// Rol mínimo requerido para la acción intentada.
  final String? requiredRole;

  @override
  String get code => 'AUTH';

  @override
  bool get isRecoverable => true;
}

/// Regla de negocio violada (ej. cerrar caja con ventas pendientes).
final class BusinessRuleFailure extends AppFailure {
  const BusinessRuleFailure({
    required super.message,
    super.technicalDetail,
    this.rule,
  });

  /// Identificador de la regla, útil para tests.
  final String? rule;

  @override
  String get code => 'BUSINESS_RULE';

  @override
  bool get isRecoverable => true;
}

/// Recurso no encontrado.
final class NotFoundFailure extends AppFailure {
  const NotFoundFailure({
    super.message = 'No se encontró el registro solicitado.',
    this.entity,
    this.identifier,
    super.technicalDetail,
  });

  final String? entity;
  final String? identifier;

  @override
  String get code => 'NOT_FOUND';

  @override
  bool get isRecoverable => true;
}

/// Fallo inesperado: se reporta como crítico en el log y en la UI.
final class UnexpectedFailure extends AppFailure {
  const UnexpectedFailure({
    super.message = 'Ocurrió un error inesperado. Se registró el detalle para soporte.',
    super.technicalDetail,
    super.cause,
    super.stackTrace,
  });

  @override
  String get code => 'UNEXPECTED';

  @override
  bool get isRecoverable => false;
}

/// Compatibilidad: convierte cualquier error en un [AppFailure] mostrable.
AppFailure toAppFailure(Object error, [StackTrace? stackTrace]) {
  if (error is AppFailure) return error;
  return UnexpectedFailure(
    technicalDetail: error.toString(),
    cause: error,
    stackTrace: stackTrace,
  );
}
