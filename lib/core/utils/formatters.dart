import 'package:intl/intl.dart';

import 'money.dart';

/// Posición del símbolo monetario.
enum CurrencySymbolPosition { before, after }

/// Configuración de formato monetario del negocio (persistida en `company`).
///
/// El formateo de dinero NO usa `intl`: se construye sobre [MoneyMath] para que
/// sea 100% determinista y reproducible (mismos separadores en el ticket, en la
/// pantalla y en la exportación), independiente del locale de Windows.
class CurrencyFormat {
  const CurrencyFormat({
    this.code = 'NIO',
    this.symbol = r'C$',
    this.decimalDigits = 2,
    this.thousandsSeparator = ',',
    this.decimalSeparator = '.',
    this.symbolPosition = CurrencySymbolPosition.before,
    this.spaceAfterSymbol = true,
  });

  /// ISO 4217 (NIO, MXN, USD, EUR, COP...).
  final String code;

  /// Símbolo visible ("C$", "$", "€").
  final String symbol;

  final int decimalDigits;
  final String thousandsSeparator;
  final String decimalSeparator;
  final CurrencySymbolPosition symbolPosition;
  final bool spaceAfterSymbol;

  bool get _isLeft => symbolPosition == CurrencySymbolPosition.before;

  /// Formatea un [Money] con separador de miles incluido. Ej: `C$ 1,234.50`.
  String money(Money value) => formatCents(value.cents);

  /// Formatea centavos directamente, con agrupación de miles.
  ///
  /// 123456 -> `C$ 1,234.56` (o `1,234.56 C$` según configuración).
  String formatCents(int cents, {bool withSymbol = true}) {
    final String raw = MoneyMath.decimalString(cents, decimalDigits);
    final bool negative = raw.startsWith('-');
    final String unsigned = negative ? raw.substring(1) : raw;
    final int dotIndex = unsigned.indexOf('.');
    final String intPart = dotIndex == -1 ? unsigned : unsigned.substring(0, dotIndex);
    final String decPart = dotIndex == -1 ? '' : unsigned.substring(dotIndex + 1);

    final StringBuffer body = StringBuffer(_groupInteger(intPart));
    if (decimalDigits > 0 && decPart.isNotEmpty) {
      body
        ..write(decimalSeparator)
        ..write(decPart);
    }
    if (!withSymbol) {
      return '${negative ? '-' : ''}$body';
    }
    // El signo queda pegado a la cifra y el símbolo en el extremo exterior:
    // `C$ -12.00` / `-12.00 C$`. Evita ambigüedades con `-C$ 12.00`.
    final String gap = spaceAfterSymbol ? ' ' : '';
    return _isLeft
        ? '$symbol$gap${negative ? '-' : ''}$body'
        : '${negative ? '-' : ''}$body$gap$symbol';
  }

  /// Alinea el importe a la derecha para columnas de cifras.
  String moneyAligned(Money value, {int width = 14}) =>
      money(value).padLeft(width, ' ');

  /// Aplica agrupación de miles a la parte entera ya sin signo.
  String _groupInteger(String digits) {
    if (digits.length <= 3) return digits;
    final StringBuffer buffer = StringBuffer();
    for (int i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) {
        buffer.write(thousandsSeparator);
      }
      buffer.write(digits[i]);
    }
    return buffer.toString();
  }
}

/// Formateadores de uso general en la UI.
abstract final class AppFormat {
  /// Cantidad física: 1 -> "1", 0.25 -> "0.25", 1.5 -> "1.5".
  static String quantity(Quantity q) => MoneyMath.quantityString(q.milli);

  /// Cantidad expresada directamente en milésimas (columnas crudas de la BD).
  ///
  /// Existe para no envolver y desenvolver un `Quantity` en cada celda de tabla.
  static String quantityMilli(int milli) => MoneyMath.quantityString(milli);

  /// Cantidad con decimales fijos (columnas de tabla).
  static String quantityFixed(Quantity q, {int decimals = 2}) {
    final double units = q.units;
    return units.toStringAsFixed(decimals);
  }

  /// Porcentaje desde basis points: 1600 bps -> "16%", 1550 -> "15.5%".
  static String percent(int bps) {
    final String raw = MoneyMath.decimalString(bps, 2);
    final String trimmed = raw.contains('.')
        ? raw.replaceFirst(RegExp(r'\.?0+$'), '')
        : raw;
    return '$trimmed%';
  }

  /// Fecha larga: `miércoles, 11 de octubre de 2026`.
  static String fullDate(DateTime date, {String locale = 'es'}) =>
      DateFormat.yMMMMEEEEd(locale).format(date);

  /// Fecha corta para tablas: `11/10/2026`.
  static String shortDate(DateTime date) => DateFormat('dd/MM/yyyy').format(date);

  /// Fecha y hora: `11/10/2026 14:32`.
  static String dateTime(DateTime date) => DateFormat('dd/MM/yyyy HH:mm').format(date);

  /// Hora corta para la barra de estado: `14:32:07`.
  static String clock(DateTime date) => DateFormat('HH:mm:ss').format(date);

  /// Timestamp legible para tickets y reportes.
  static String stamp(DateTime date) => DateFormat('dd/MM/yyyy HH:mm:ss').format(date);

  /// Hora compacta: `14:32`.
  static String time(DateTime date) => DateFormat('HH:mm').format(date);

  /// Nombres de mes para encabezados de gráficos.
  static String monthName(DateTime date, {String locale = 'es'}) =>
      DateFormat.MMMM(locale).format(date);

  /// Número de documento (folio) con ceros a la izquierda: 1 -> `000001`.
  static String folio(int number, {int width = 6}) => number.toString().padLeft(width, '0');

  /// Teléfono / NIT agrupado para lectura en tablas.
  static String taxId(String raw) {
    final String clean = raw.replaceAll(RegExp(r'[^0-9A-Za-z-]'), '');
    return clean.isEmpty ? raw : clean;
  }

  /// Archivo seguro para Windows (sin caracteres prohibidos).
  static String safeFileName(String input) {
    final String sanitized = input.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_');
    return sanitized.trim().isEmpty ? 'archivo' : sanitized.trim();
  }

  /// Duración legible para reintentos de sincronización: `12s`, `3m 20s`.
  static String shortDuration(Duration d) {
    if (d.inSeconds < 60) return '${d.inSeconds}s';
    final int minutes = d.inMinutes;
    final int seconds = d.inSeconds % 60;
    if (minutes < 60) return seconds == 0 ? '${minutes}m' : '${minutes}m ${seconds}s';
    final int hours = d.inHours;
    return '${hours}h ${minutes % 60}m';
  }
}
