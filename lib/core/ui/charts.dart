import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../domain/enums.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';
import '../utils/money.dart';

/// Gráficos del módulo de reportes.
///
/// Se dibujan con `CustomPainter` en lugar de usar una librería de gráficos:
/// en un POS los reportes deben abrirse al instante en equipos modestos
/// (CPU integrada, 4 GB de RAM) y solo se necesitan tres formas —barras,
/// línea/área y anillo—. Menos dependencias, menos asignaciones y control total
/// de los colores corporativos.
///
/// Todos los importes se formatean fuera del `paint`, y el pintado evita crear
/// objetos por píxel: el `shouldRepaint` compara listas por longitud y valores.
///
/// Nota: `TextPainter` se construye una vez por gráfico, no por barra.
class SalesBarChart extends StatelessWidget {
  const SalesBarChart({
    super.key,
    required this.bars,
    this.height = 240,
    this.showValues = true,
    this.color = AppColors.cyan,
    this.currency = const CurrencyFormat(),
  });

  final List<ChartBar> bars;
  final double height;
  final bool showValues;
  final Color color;
  final CurrencyFormat currency;

  @override
  Widget build(BuildContext context) {
    if (bars.isEmpty) {
      return SizedBox(
        height: height,
        child: Center(
          child: Text(
            'Sin datos en el período seleccionado',
            style: AppTypography.caption.copyWith(color: AppColors.textHint),
          ),
        ),
      );
    }
    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) => CustomPaint(
          size: Size(constraints.maxWidth, height),
          painter: _BarChartPainter(
            bars: bars,
            showValues: showValues,
            color: color,
            currency: currency,
          ),
        ),
      ),
    );
  }
}

/// Punto de un gráfico de barras.
@immutable
class ChartBar {
  const ChartBar({required this.label, required this.value});

  final String label;
  final Money value;
}

class _BarChartPainter extends CustomPainter {
  _BarChartPainter({
    required this.bars,
    required this.showValues,
    required this.color,
    required this.currency,
  });

  final List<ChartBar> bars;
  final bool showValues;
  final Color color;
  final CurrencyFormat currency;

  @override
  void paint(Canvas canvas, Size size) {
    const double axisHeight = 26;
    const double topPadding = 22;
    final double chartHeight = size.height - axisHeight - topPadding;
    final int maxCents = bars
        .map((ChartBar bar) => bar.value.cents)
        .fold<int>(0, (int max, int value) => value > max ? value : max);
    final int effectiveMax = maxCents == 0 ? 1 : maxCents;

    // Líneas guía horizontales.
    final Paint grid = Paint()
      ..color = AppColors.grey200
      ..strokeWidth = 1;
    for (int i = 0; i <= 4; i++) {
      final double y = topPadding + chartHeight * (i / 4);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    final double slot = size.width / bars.length;
    final double barWidth = math.min(46, slot * 0.62);
    final TextPainter label = TextPainter(textDirection: TextDirection.ltr);
    final TextPainter value = TextPainter(textDirection: TextDirection.ltr);

    for (int i = 0; i < bars.length; i++) {
      final ChartBar bar = bars[i];
      final double ratio = bar.value.cents / effectiveMax;
      final double barHeight = (chartHeight * ratio).clamp(2, chartHeight);
      final double left = slot * i + (slot - barWidth) / 2;
      final Rect rect = Rect.fromLTWH(
        left,
        topPadding + chartHeight - barHeight,
        barWidth,
        barHeight,
      );

      // Degradado vertical del cian corporativo al azul profundo: da volumen
      // sin sombras ni efectos costosos.
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(4)),
        Paint()
          ..shader = ui.Gradient.linear(
            rect.topCenter,
            rect.bottomCenter,
            <Color>[color, AppColors.deepBlue],
          ),
      );

      if (showValues && bar.value.isPositive) {
        value.text = TextSpan(
          text: _compact(bar.value),
          style: AppTypography.caption.copyWith(
            fontSize: 10,
            color: AppColors.textSecondary,
            fontWeight: FontWeight.w600,
          ),
        );
        value.layout();
        value.paint(
          canvas,
          Offset(rect.center.dx - value.width / 2, rect.top - 14),
        );
      }

      label.text = TextSpan(
        text: bar.label,
        style: AppTypography.caption.copyWith(fontSize: 10, color: AppColors.textHint),
      );
      label.layout(maxWidth: slot);
      label.paint(
        canvas,
        Offset(rect.center.dx - label.width / 2, size.height - axisHeight + 6),
      );
    }
  }

  /// Importe abreviado para la etiqueta superior de cada barra.
  static String _compact(Money value) {
    final int cents = value.cents;
    if (cents >= 100000000) {
      return '${(cents / 100000000).toStringAsFixed(1)}M';
    }
    if (cents >= 100000) {
      return '${(cents / 100000).toStringAsFixed(1)}k';
    }
    return (cents / 100).toStringAsFixed(0);
  }

  @override
  bool shouldRepaint(covariant _BarChartPainter oldDelegate) =>
      oldDelegate.bars.length != bars.length ||
      oldDelegate.color != color ||
      oldDelegate.showValues != showValues ||
      !_sameValues(oldDelegate.bars, bars);

  static bool _sameValues(List<ChartBar> a, List<ChartBar> b) {
    for (int i = 0; i < a.length; i++) {
      if (a[i].value != b[i].value || a[i].label != b[i].label) return false;
    }
    return true;
  }
}

/// Gráfico de línea con área rellena (tendencia de ventas).
class SalesLineChart extends StatelessWidget {
  const SalesLineChart({
    super.key,
    required this.points,
    this.height = 220,
    this.color = AppColors.deepBlue,
    this.currency = const CurrencyFormat(),
  });

  final List<ChartBar> points;
  final double height;
  final Color color;
  final CurrencyFormat currency;

  @override
  Widget build(BuildContext context) {
    if (points.length < 2) {
      return SizedBox(
        height: height,
        child: Center(
          child: Text(
            'Se necesitan al menos dos períodos para ver la tendencia',
            style: AppTypography.caption.copyWith(color: AppColors.textHint),
          ),
        ),
      );
    }
    return SizedBox(
      height: height,
      child: CustomPaint(
        size: Size.infinite,
        painter: _LineChartPainter(points: points, color: color),
      ),
    );
  }
}

class _LineChartPainter extends CustomPainter {
  _LineChartPainter({required this.points, required this.color});

  final List<ChartBar> points;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const double bottomPadding = 24;
    const double topPadding = 10;
    final double chartHeight = size.height - bottomPadding - topPadding;
    final int maxCents = points
        .map((ChartBar point) => point.value.cents)
        .fold<int>(0, (int max, int value) => value > max ? value : max);
    final int effectiveMax = maxCents == 0 ? 1 : maxCents;

    final double step = size.width / (points.length - 1);
    final Path line = Path();
    final Path area = Path()..moveTo(0, size.height - bottomPadding);

    for (int i = 0; i < points.length; i++) {
      final double x = step * i;
      final double y = topPadding +
          chartHeight * (1 - points[i].value.cents / effectiveMax);
      if (i == 0) {
        line.moveTo(x, y);
      } else {
        line.lineTo(x, y);
      }
      area.lineTo(x, y);
    }
    area
      ..lineTo(size.width, size.height - bottomPadding)
      ..close();

    // Área con degradado translúcido.
    canvas.drawPath(
      area,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, topPadding),
          Offset(0, size.height - bottomPadding),
          <Color>[
            color.withValues(alpha: 0.22),
            color.withValues(alpha: 0.02),
          ],
        ),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );

    // Punto final destacado (el dato "de hoy").
    final Offset last = Offset(step * (points.length - 1),
        topPadding + chartHeight * (1 - points.last.value.cents / effectiveMax));
    canvas.drawCircle(last, 4, Paint()..color = color);
    canvas.drawCircle(last, 2, Paint()..color = AppColors.white);

    // Etiquetas del eje X: solo las necesarias para no saturar.
    final int every = (points.length / 7).ceil();
    final TextPainter label = TextPainter(textDirection: TextDirection.ltr);
    for (int i = 0; i < points.length; i += every) {
      label.text = TextSpan(
        text: points[i].label,
        style: AppTypography.caption.copyWith(fontSize: 9.5, color: AppColors.textHint),
      );
      label.layout(maxWidth: step * every);
      label.paint(
        canvas,
        Offset(
          (step * i - label.width / 2).clamp(0, size.width - label.width),
          size.height - bottomPadding + 6,
        ),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _LineChartPainter oldDelegate) =>
      oldDelegate.points.length != points.length ||
      oldDelegate.color != color ||
      !_BarChartPainter._sameValues(oldDelegate.points, points);
}

/// Anillo de participación (formas de pago, categorías, cajeros).
class ShareDonutChart extends StatelessWidget {
  const ShareDonutChart({
    super.key,
    required this.slices,
    this.height = 220,
    this.centerLabel = 'Total',
    this.currency = const CurrencyFormat(),
  });

  final List<ChartBar> slices;
  final double height;
  final String centerLabel;
  final CurrencyFormat currency;

  static const List<Color> palette = <Color>[
    AppColors.deepBlue,
    AppColors.cyan,
    AppColors.orange,
    AppColors.success,
    AppColors.warning,
    AppColors.deepBlue600,
    AppColors.grey400,
  ];

  @override
  Widget build(BuildContext context) {
    final Money total = slices.fold(
      Money.zero,
      (Money sum, ChartBar slice) => sum + slice.value,
    );

    if (slices.isEmpty || total.isZero) {
      return SizedBox(
        height: height,
        child: Center(
          child: Text(
            'Sin datos en el período seleccionado',
            style: AppTypography.caption.copyWith(color: AppColors.textHint),
          ),
        ),
      );
    }

    return SizedBox(
      height: height,
      child: Row(
        children: <Widget>[
          SizedBox(
            width: height,
            height: height,
            child: Stack(
              alignment: Alignment.center,
              children: <Widget>[
                CustomPaint(
                  size: Size.square(height),
                  painter: _DonutPainter(slices: slices, total: total),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      centerLabel.toUpperCase(),
                      style: AppTypography.label.copyWith(
                        fontSize: 9,
                        color: AppColors.textHint,
                      ),
                    ),
                    Text(
                      currency.money(total),
                      style: AppTypography.subtitle.copyWith(fontSize: 15),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (int i = 0; i < slices.length; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: <Widget>[
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: palette[i % palette.length],
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            slices[i].label,
                            style: AppTypography.caption,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          currency.money(slices[i].value),
                          style: AppTypography.table.copyWith(fontSize: 11.5),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 46,
                          child: Text(
                            '${(slices[i].value.cents * 100 / total.cents).toStringAsFixed(1)}%',
                            textAlign: TextAlign.right,
                            style: AppTypography.caption.copyWith(
                              color: AppColors.textHint,
                              fontSize: 10.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DonutPainter extends CustomPainter {
  _DonutPainter({required this.slices, required this.total});

  final List<ChartBar> slices;
  final Money total;

  @override
  void paint(Canvas canvas, Size size) {
    final double stroke = size.width * 0.17;
    final Rect rect = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: (size.width - stroke) / 2,
    );
    double start = -math.pi / 2;
    for (int i = 0; i < slices.length; i++) {
      final double sweep =
          (slices[i].value.cents / total.cents) * math.pi * 2;
      canvas.drawArc(
        rect,
        start + 0.02,
        math.max(sweep - 0.04, 0.01),
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..color = ShareDonutChart.palette[i % ShareDonutChart.palette.length],
      );
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter oldDelegate) =>
      oldDelegate.total != total || oldDelegate.slices.length != slices.length;
}

/// Barra de progreso horizontal (ranking de productos/cajeros).
class RankedBar extends StatelessWidget {
  const RankedBar({
    super.key,
    required this.label,
    required this.value,
    required this.max,
    this.subtitle,
    this.color = AppColors.cyan,
    this.trailing,
  });

  final String label;
  final Money value;
  final Money max;
  final String? subtitle;
  final Color color;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final double ratio =
        max.isZero ? 0 : (value.cents / max.cents).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  label,
                  style: AppTypography.body.copyWith(fontSize: 12.5),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 7,
              backgroundColor: AppColors.grey100,
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
          if (subtitle != null) ...<Widget>[
            const SizedBox(height: 2),
            Text(
              subtitle!,
              style: AppTypography.caption.copyWith(
                fontSize: 10,
                color: AppColors.textHint,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Etiqueta de método de pago con su icono (usado en reportes y arqueos).
extension PaymentMethodPresentation on PaymentMethod {
  IconData get icon => switch (this) {
        PaymentMethod.cash => Icons.payments_outlined,
        PaymentMethod.card => Icons.credit_card,
        PaymentMethod.transfer => Icons.account_balance_outlined,
        PaymentMethod.credit => Icons.handshake_outlined,
        PaymentMethod.other => Icons.more_horiz,
      };

  Color get color => switch (this) {
        PaymentMethod.cash => AppColors.success,
        PaymentMethod.card => AppColors.deepBlue,
        PaymentMethod.transfer => AppColors.cyan,
        PaymentMethod.credit => AppColors.orange,
        PaymentMethod.other => AppColors.grey500,
      };
}
