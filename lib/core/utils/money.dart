import 'package:flutter/foundation.dart';

/// Aritmética monetaria determinista.
///
/// **Decisión de arquitectura:** todo importe se almacena y se calcula como
/// `int` en la unidad mínima (centavos). Nunca se usa `double` para dinero.
///
/// Motivo: 0.1 + 0.2 != 0.3 en IEEE-754. En un POS un centavo perdido por
/// venta se convierte en descuadre de caja al cierre del turno, y en tickets
/// fiscales es directamente inaceptable.
///
/// Se usa `int` (64 bits) y no `BigInt` porque el rango de 64 bits
/// (±9.22e18 centavos ≈ 9.2e16 unidades monetarias) es inalcanzable para
/// cualquier operación de punto de venta.
@immutable
class Money implements Comparable<Money> {
  const Money(this.cents);

  /// Crea un [Money] desde unidades (ej. 12.50 -> 1250 centavos),
  /// redondeando al centavo más cercano.
  factory Money.fromUnits(num units) => Money(MoneyMath.roundHalfUp(units * 100));

  /// Crea un [Money] desde un string de entrada de usuario ("12.50", "12,50").
  /// Devuelve `null` si el texto no es un importe válido.
  static Money? tryParse(String? input) {
    if (input == null) return null;
    final String normalized = input.trim().replaceAll(',', '.').replaceAll(' ', '');
    if (normalized.isEmpty) return null;
    final num? value = num.tryParse(normalized);
    if (value == null || value.isNaN || value.isInfinite) return null;
    return Money.fromUnits(value);
  }

  static const Money zero = Money(0);

  /// Importe en centavos (unidad mínima).
  final int cents;

  bool get isZero => cents == 0;
  bool get isNegative => cents < 0;
  bool get isPositive => cents > 0;

  /// Valor en unidades monetarias. **Solo para mostrar, nunca para calcular.**
  double get units => cents / 100;

  Money operator +(Money other) => Money(cents + other.cents);
  Money operator -(Money other) => Money(cents - other.cents);
  Money operator -() => Money(-cents);

  /// Multiplica por una cantidad entera exacta (ej. 3 unidades en el carrito).
  Money operator *(int quantity) => Money(cents * quantity);

  /// Reparte el importe en [parts] partes iguales sin perder centavos
  /// (los centavos sobrantes se reparten a las primeras cuotas).
  ///
  /// Útil para pagos mixtos, propinas y prorrateos de descuento.
  List<Money> splitAcross(int parts) {
    if (parts <= 0) {
      throw ArgumentError.value(parts, 'parts', 'Debe ser mayor que cero');
    }
    final int base = cents ~/ parts;
    final int remainder = cents - (base * parts);
    return List<Money>.generate(
      parts,
      (int i) => Money(base + (i < remainder.abs() ? (remainder.isNegative ? -1 : 1) : 0)),
      growable: false,
    );
  }

  Money clampMin(Money min) => cents < min.cents ? min : this;
  Money clampMax(Money max) => cents > max.cents ? max : this;

  Money get abs => Money(cents.abs());

  @override
  int compareTo(Money other) => cents.compareTo(other.cents);

  bool operator <(Money other) => cents < other.cents;
  bool operator <=(Money other) => cents <= other.cents;
  bool operator >(Money other) => cents > other.cents;
  bool operator >=(Money other) => cents >= other.cents;

  @override
  bool operator ==(Object other) => other is Money && other.cents == cents;

  @override
  int get hashCode => cents.hashCode;

  @override
  String toString() => 'Money(${MoneyMath.decimalString(cents, 2)})';
}

/// Utilidades de aritmética entera con redondeo bancario-neutral
/// (half-up, "away from zero" para negativos), el criterio que espera
/// un contador y el que usan la mayoría de las normativas fiscales.
abstract final class MoneyMath {
  /// `(a * b) / c` sin perder precisión, redondeando al entero más cercano.
  ///
  /// Evita el desbordamiento intermedio usando `~/` sobre enteros de 64 bits.
  static int mulDiv(int a, int b, int c) {
    if (c == 0) {
      throw ArgumentError.value(c, 'c', 'División por cero');
    }
    final int product = a * b;
    // Redondeo half-up simétrico: (|product| + |c|/2) con signo.
    final int sign = (product.isNegative ? -1 : 1) * (c.isNegative ? -1 : 1);
    final int absProduct = product.abs();
    final int absC = c.abs();
    final int quotient = (absProduct + (absC ~/ 2)) ~/ absC;
    return sign * quotient;
  }

  /// Redondea al entero más cercano, half-up (0.5 -> 1, 1.5 -> 2, -1.5 -> -2).
  static int roundHalfUp(num value) {
    final bool negative = value < 0;
    final int result = (value.abs() + 0.5).floor();
    return negative ? -result : result;
  }

  /// Aplica una tasa en *basis points* (1 bps = 0.01%). Ej: IVA 16% = 1600 bps.
  static Money applyBps(Money base, int bps) => Money(mulDiv(base.cents, bps, 10000));

  /// Extrae la parte correspondiente a [bps] de un importe que YA los incluye.
  ///
  /// Ej. precio con IVA incluido de 116.00 a 1600 bps -> 16.00 de impuesto.
  static Money extractBps(Money gross, int bps) {
    if (bps == 0) return Money.zero;
    return Money(mulDiv(gross.cents, bps, 10000 + bps));
  }

  /// Formatea centavos como string decimal con [decimals] posiciones.
  /// Implementación propia (sin `intl`) para poder usarse en isolates puros.
  static String decimalString(int cents, int decimals) {
    final bool negative = cents < 0;
    final int abs = cents.abs();
    if (decimals <= 0) return '${negative ? '-' : ''}$abs';
    final int factor = _pow10(decimals);
    final int intPart = abs ~/ factor;
    final int decPart = abs % factor;
    final String dec = decPart.toString().padLeft(decimals, '0');
    return '${negative ? '-' : ''}$intPart.$dec';
  }

  /// Formatea una cantidad en milésimas como string decimal de 3 posiciones.
  static String quantityString(int milli, {int decimals = 3}) {
    final bool negative = milli < 0;
    final int abs = milli.abs();
    final int factor = _pow10(decimals);
    final int intPart = abs ~/ factor;
    final int decPart = abs % factor;
    final String dec = decPart.toString().padLeft(decimals, '0');
    // Recorta ceros sobrantes: 2.500 -> 2.5, 2.000 -> 2
    final String trimmed = dec.replaceFirst(RegExp(r'0+$'), '');
    return '${negative ? '-' : ''}$intPart${trimmed.isEmpty ? '' : '.$trimmed'}';
  }

  static int _pow10(int exponent) {
    int result = 1;
    for (int i = 0; i < exponent; i++) {
      result *= 10;
    }
    return result;
  }
}

/// Cantidad física en **milésimas de unidad** (1 unidad = 1000).
///
/// Permite manejar productos por unidad y por peso (0.250 kg = 250 milésimas)
/// sin aritmética de punto flotante, evitando diferencias de stock al milímetro.
@immutable
class Quantity implements Comparable<Quantity> {
  const Quantity(this.milli);

  factory Quantity.fromUnits(num units) => Quantity(MoneyMath.roundHalfUp(units * 1000));

  static Quantity? tryParse(String? input) {
    if (input == null) return null;
    final String normalized = input.trim().replaceAll(',', '.').replaceAll(' ', '');
    if (normalized.isEmpty) return null;
    final num? value = num.tryParse(normalized);
    if (value == null) return null;
    return Quantity.fromUnits(value);
  }

  static const Quantity zero = Quantity(0);

  static const int unitsPerWhole = 1000;

  /// Cantidad en milésimas.
  final int milli;

  bool get isZero => milli == 0;
  bool get isNegative => milli < 0;
  bool get isPositive => milli > 0;
  bool get isWhole => milli % unitsPerWhole == 0;

  double get units => milli / 1000;

  /// Distancia absoluta (ajustes de inventario por conteo físico).
  Quantity get abs => Quantity(milli.abs);

  Quantity operator +(Quantity other) => Quantity(milli + other.milli);
  Quantity operator -(Quantity other) => Quantity(milli - other.milli);
  Quantity operator -() => Quantity(-milli);

  /// Multiplica por un factor entero (ej. "x12").
  Quantity operator *(int factor) => Quantity(milli * factor);

  /// Valor monetario = precio unitario * cantidad (redondeo al centavo).
  Money priceFor(Money unitPrice) => Money(MoneyMath.mulDiv(unitPrice.cents, milli, 1000));

  @override
  int compareTo(Quantity other) => milli.compareTo(other.milli);

  bool operator <(Quantity other) => milli < other.milli;
  bool operator <=(Quantity other) => milli <= other.milli;
  bool operator >(Quantity other) => milli > other.milli;
  bool operator >=(Quantity other) => milli >= other.milli;

  @override
  bool operator ==(Object other) => other is Quantity && other.milli == milli;

  @override
  int get hashCode => milli.hashCode;

  @override
  String toString() => MoneyMath.quantityString(milli);
}
