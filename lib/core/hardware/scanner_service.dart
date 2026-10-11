import 'dart:async';

import 'package:flutter/services.dart';

import '../config/app_config.dart';
import '../logging/app_logger.dart';

/// Detección de lectores de código de barras en modo "teclado" (keyboard wedge).
///
/// El 95 % de los lectores de POS se comportan como un teclado: "escriben" los
/// dígitos a gran velocidad y terminan con `Enter`. No requieren driver ni SDK.
///
/// Cómo se distingue de un humano tecleando: por **velocidad**. Un operador
/// escribe a 200-400 ms por tecla; un lector emite la ráfaga completa en menos
/// de 50 ms por carácter. Si además se recibe el terminador, se confirma.
///
/// Este detector permite además que el POS no pierda el escaneo aunque el foco
/// esté en la grilla de productos o en una tabla: se instala como un
/// *listener* global de teclado en la capa de la aplicación.
class BarcodeScannerDetector {
  BarcodeScannerDetector({
    this.burstWindow = AppConfig.scannerBurstWindow,
    this.minLength = 3,
    this.maxLength = 64,
    this.terminators = const <LogicalKeyboardKey>{
      LogicalKeyboardKey.enter,
      LogicalKeyboardKey.numpadEnter,
      LogicalKeyboardKey.tab,
    },
  });

  /// Tiempo máximo entre caracteres para considerarlos parte de una ráfaga.
  final Duration burstWindow;

  /// Longitud mínima para aceptar un escaneo (evita disparar con tecleos).
  final int minLength;
  final int maxLength;

  /// Teclas que cierran un código.
  final Set<LogicalKeyboardKey> terminators;

  final StringBuffer _buffer = StringBuffer();
  DateTime? _lastKeyAt;
  DateTime? _burstStartAt;

  final StreamController<String> _controller = StreamController<String>.broadcast();

  /// Códigos detectados (ya validados como ráfaga).
  Stream<String> get scans => _controller.stream;

  /// Código acumulado hasta el momento (para depuración en pantalla).
  String get pending => _buffer.toString();

  /// Procesa un evento de teclado.
  ///
  /// Devuelve `true` si el evento debe **consumirse** (ya forma parte de un
  /// escaneo y no debe llegar a los campos de texto).
  bool handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;

    final LogicalKeyboardKey key = event.logicalKey;

    if (terminators.contains(key)) {
      return _flush(force: false);
    }

    final String? character = event.character;
    if (character == null || character.isEmpty) return false;

    // Solo se aceptan caracteres imprimibles: cualquier tecla de control
    // (Ctrl, Alt, flechas) cancela la ráfaga.
    final int code = character.codeUnitAt(0);
    if (code < 0x20 || code == 0x7F) {
      _reset();
      return false;
    }

    final DateTime now = DateTime.now();
    final DateTime? last = _lastKeyAt;
    if (last != null && now.difference(last) > burstWindow) {
      // Pausa humana: la ráfaga anterior era tecleo, no escaneo.
      _reset();
    }

    _lastKeyAt = now;
    _burstStartAt ??= now;
    _buffer.write(character);

    if (_buffer.length > maxLength) {
      _reset();
    }
    // Mientras la ráfaga siga siendo rápida, se consume el evento para que el
    // campo de búsqueda no se ensucie con el código (y no dispare búsquedas
    // intermedias que ralentizan el POS).
    return _isBurst;
  }

  /// ¿La entrada actual se comporta como un lector?
  bool get _isBurst {
    final DateTime? start = _burstStartAt;
    final DateTime? last = _lastKeyAt;
    if (start == null || last == null) return false;
    if (_buffer.length < 2) return false;
    return last.difference(start) <= burstWindow * _buffer.length;
  }

  /// Cierra la captura y emite el código si cumple los requisitos.
  bool _flush({required bool force}) {
    final String code = _buffer.toString().trim();
    _reset();
    if (code.length < minLength) return false;
    if (!_controller.isClosed) {
      _controller.add(code);
    }
    Log.debug('scanner', 'Código capturado', data: <String, Object?>{'code': code});
    return true;
  }

  /// Fuerza el cierre (útil si el lector no envía terminador).
  void flushPending() => _flush(force: true);

  void _reset() {
    _buffer.clear();
    _lastKeyAt = null;
    _burstStartAt = null;
  }

  /// Instala el detector como manejador global de teclado.
  ///
  /// Devuelve una función para retirarlo (se llama en `dispose`).
  VoidCallback install() {
    bool handler(KeyEvent event) => handleKeyEvent(event);
    HardwareKeyboard.instance.addHandler(handler);
    return () => HardwareKeyboard.instance.removeHandler(handler);
  }

  Future<void> dispose() async {
    _reset();
    await _controller.close();
  }
}

/// Prefijo/sufijo configurable de algunos lectores (ej. `]C1` de Honeywell).
///
/// Se aplica al código capturado para limpiarlo antes de buscar el producto.
class ScannerNormalizer {
  const ScannerNormalizer({this.prefix = '', this.suffix = ''});

  final String prefix;
  final String suffix;

  /// Devuelve el código en su forma canónica (sin prefijos del lector).
  String normalize(String raw) {
    String value = raw.trim();
    if (prefix.isNotEmpty && value.startsWith(prefix)) {
      value = value.substring(prefix.length);
    }
    if (suffix.isNotEmpty && value.endsWith(suffix)) {
      value = value.substring(0, value.length - suffix.length);
    }
    return value.trim();
  }

  /// ¿El valor parece un código de barras y no un nombre de producto?
  static bool looksLikeBarcode(String value) =>
      RegExp(r'^[0-9A-Za-z\-\.]{3,64}$').hasMatch(value.trim());
}
