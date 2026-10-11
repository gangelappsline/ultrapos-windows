import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// Resultado de un hash de PIN.
class PinHashResult {
  const PinHashResult({required this.encoded, required this.saltBase64});

  /// Cadena autocontenida: `pbkdf2-sha256$<iteraciones>$<sal>$<hash>`.
  final String encoded;

  /// Sal en base64 (se guarda aparte para poder auditar/rehashear).
  final String saltBase64;
}

/// Derivación y verificación de PIN para los usuarios del POS.
///
/// Diseño:
///  * **PBKDF2-HMAC-SHA256** con sal aleatoria de 16 bytes por usuario.
///  * El formato del hash **incluye el número de iteraciones**
///    (`pbkdf2-sha256$30000$...`). Esto permite subir el coste en el futuro y
///    rehashear en el siguiente login sin invalidar los PIN existentes.
///  * Comparación en **tiempo constante** para no filtrar información por
///    temporización (aunque el vector realista en una caja es otro).
///
/// Nota de ingeniería: se usa 30.000 iteraciones con la implementación pura
/// de Dart del paquete `crypto`. Medido en hardware de caja típico supone
/// ~80-150 ms, aceptable para el login del cajero. Para entornos con requisitos
/// de compliance más estrictos, sustituir esta clase por una implementación
/// BCrypt nativa de Windows (`bcrypt.dll` -> `BCryptDeriveKeyPBKDF2`) sin tocar
/// el resto de la aplicación: el hash es autocontenido.
abstract final class PinHasher {
  static const String algorithm = 'pbkdf2-sha256';
  static const int defaultIterations = 30000;
  static const int keyLengthBytes = 32;
  static const int saltLengthBytes = 16;

  static final Random _random = Random.secure();

  /// Genera un hash nuevo para [pin].
  static PinHashResult hash(String pin, {int iterations = defaultIterations}) {
    final Uint8List salt = _randomBytes(saltLengthBytes);
    final Uint8List key = _pbkdf2(
      pin: utf8.encode(pin),
      salt: salt,
      iterations: iterations,
      length: keyLengthBytes,
    );
    final String saltBase64 = base64Encode(salt);
    return PinHashResult(
      encoded: '$algorithm\$$iterations\$$saltBase64\$${base64Encode(key)}',
      saltBase64: saltBase64,
    );
  }

  /// Verifica [pin] contra un hash con formato `pbkdf2-sha256$it$sal$hash`.
  static bool verify(String pin, String? encodedHash, {String? legacySaltBase64}) {
    if (encodedHash == null || encodedHash.isEmpty) return false;
    final List<String> parts = encodedHash.split(r'$');
    if (parts.length != 4 || parts[0] != algorithm) {
      // Formato desconocido: no se autentica (fail closed).
      return false;
    }
    final int? iterations = int.tryParse(parts[1]);
    if (iterations == null || iterations <= 0) return false;

    final Uint8List salt;
    final Uint8List expected;
    try {
      salt = base64Decode(parts[2]);
      expected = base64Decode(parts[3]);
    } on FormatException {
      return false;
    }

    final Uint8List actual = _pbkdf2(
      pin: utf8.encode(pin),
      salt: salt,
      iterations: iterations,
      length: expected.length,
    );
    return _constantTimeEquals(expected, actual);
  }

  /// ¿Este hash debería rehashearse por haber quedado obsoleto el coste?
  static bool needsRehash(String? encodedHash, {int targetIterations = defaultIterations}) {
    if (encodedHash == null) return true;
    final List<String> parts = encodedHash.split(r'$');
    if (parts.length != 4) return true;
    final int? iterations = int.tryParse(parts[1]);
    return iterations == null || iterations < targetIterations;
  }

  /// Longitud mínima exigida a un PIN de POS (configurable en Ajustes).
  static const int minPinLength = 4;
  static const int maxPinLength = 12;

  /// Valida la forma del PIN antes de hashear (mensajes para el cajero).
  static String? validate(String pin, {int minLength = minPinLength}) {
    if (pin.isEmpty) return 'Ingrese el PIN.';
    if (pin.length < minLength) return 'El PIN debe tener al menos $minLength dígitos.';
    if (pin.length > maxPinLength) return 'El PIN no puede exceder $maxPinLength dígitos.';
    if (!RegExp(r'^\d+$').hasMatch(pin)) return 'El PIN solo admite dígitos.';
    if (RegExp(r'^(\d)\1+$').hasMatch(pin)) return 'El PIN no puede ser un dígito repetido.';
    if (_isSequential(pin)) return 'El PIN no puede ser una secuencia (1234, 9876).';
    return null;
  }

  static bool _isSequential(String pin) {
    bool ascending = true;
    bool descending = true;
    for (int i = 1; i < pin.length; i++) {
      final int delta = pin.codeUnitAt(i) - pin.codeUnitAt(i - 1);
      if (delta != 1) ascending = false;
      if (delta != -1) descending = false;
    }
    return ascending || descending;
  }

  // ---------------------------------------------------------------------------
  // PBKDF2 (RFC 2898) sobre HMAC-SHA256 — implementación propia para no añadir
  // dependencias y para poder ejecutarse en un isolate de sincronización.
  // ---------------------------------------------------------------------------
  static Uint8List _pbkdf2({
    required List<int> pin,
    required Uint8List salt,
    required int iterations,
    required int length,
  }) {
    final crypto.Hmac hmac = crypto.Hmac(crypto.sha256, pin);
    final int blockCount = (length / 32).ceil();
    final BytesBuilder output = BytesBuilder(copy: false);

    for (int block = 1; block <= blockCount; block++) {
      // U1 = PRF(P, S || INT_BE(block))
      final List<int> input = <int>[...salt, ..._intToBigEndian(block)];
      Uint8List u = Uint8List.fromList(hmac.convert(input).bytes);
      final Uint8List accumulator = Uint8List.fromList(u);

      for (int iteration = 1; iteration < iterations; iteration++) {
        u = Uint8List.fromList(hmac.convert(u).bytes);
        for (int i = 0; i < accumulator.length; i++) {
          accumulator[i] ^= u[i];
        }
      }
      output.add(accumulator);
    }

    return Uint8List.fromList(output.toBytes().sublist(0, length));
  }

  static List<int> _intToBigEndian(int value) => <int>[
        (value >> 24) & 0xFF,
        (value >> 16) & 0xFF,
        (value >> 8) & 0xFF,
        value & 0xFF,
      ];

  static Uint8List _randomBytes(int length) {
    final Uint8List bytes = Uint8List(length);
    for (int i = 0; i < length; i++) {
      bytes[i] = _random.nextInt(256);
    }
    return bytes;
  }

  /// Comparación en tiempo constante (no sale antes al encontrar una diferencia).
  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    int diff = 0;
    for (int i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
