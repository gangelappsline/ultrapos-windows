import 'dart:math';

import 'package:uuid/uuid.dart';

/// Generación de identificadores de UltraPOS.
///
/// * **UUID v4** para la identidad global de cada fila (`uuid`). Es la clave
///   que permite que dos cajas vendan offline y luego se fusionen en la nube
///   sin colisiones (probabilidad despreciable).
/// * **opId** para la cola de sincronización: además de ser único, funciona
///   como *idempotency key* ante el servidor.
/// * **Folios** legibles (`A-000123`) generados a partir de una secuencia
///   transaccional en SQLite, nunca en memoria (dos hilos no pueden repetir
///   folio).
abstract final class IdGenerator {
  static const Uuid _uuid = Uuid();
  static final Random _random = Random.secure();

  /// UUID v4 en minúsculas.
  static String uuid() => _uuid.v4();

  /// Identificador de operación de sincronización (idempotency key).
  static String opId() => _uuid.v4();

  /// Identificador de una línea de carrito o de pedido en curso.
  ///
  /// No viaja a la nube ni a la base de datos: solo identifica la línea dentro
  /// de la venta que se está capturando (el mismo producto puede aparecer en
  /// dos líneas con precios distintos y ambas deben ser distinguibles).
  static String lineId() => 'L${_uuid.v4().substring(0, 12)}';

  /// Código corto legible para sesiones y comprobantes: `K7F2-9AB3`.
  static String shortCode({int groups = 2, int groupLength = 4}) {
    const String alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final StringBuffer buffer = StringBuffer();
    for (int g = 0; g < groups; g++) {
      if (g > 0) buffer.write('-');
      for (int i = 0; i < groupLength; i++) {
        buffer.write(alphabet[_random.nextInt(alphabet.length)]);
      }
    }
    return buffer.toString();
  }

  /// Prefijo de folios por defecto si el administrador no configuró uno.
  /// Se genera con letras A-Z, lo que permite hasta 26 cajas sin ambigüedad.
  static String defaultFolioPrefix(int stationIndex) {
    final int index = stationIndex.clamp(0, 25);
    return String.fromCharCode(65 + index);
  }

  /// Folio formateado: prefijo + número con ceros a la izquierda.
  static String folio(String prefix, int number, {int width = 6}) =>
      '$prefix-${number.toString().padLeft(width, '0')}';

  /// Nombre de archivo de respaldo con marca de tiempo ordenable.
  static String backupFileName(DateTime when, {String prefix = 'ultrapos_backup'}) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${prefix}_${when.year}${two(when.month)}${two(when.day)}'
        '_${two(when.hour)}${two(when.minute)}${two(when.second)}.sqlite';
  }
}
