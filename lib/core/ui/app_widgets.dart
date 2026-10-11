import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/enums.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';
import '../utils/formatters.dart';
import '../utils/money.dart';

/// Componentes de interfaz reutilizables.
///
/// Todos están pensados para **escritorio**: alturas compactas (34-38 px),
/// información densa, foco de teclado visible y atajos a la vista. El objetivo
/// es que la aplicación se sienta como software nativo de Windows y no como una
/// aplicación móvil ampliada.

/// Tarjeta con título opcional y acciones.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.title,
    this.subtitle,
    this.actions = const <Widget>[],
    this.padding = const EdgeInsets.all(AppSpacing.md),
    this.margin = EdgeInsets.zero,
    this.trailing,
    this.color,
    this.border = true,
    this.height,
  });

  final Widget child;
  final String? title;
  final String? subtitle;
  final List<Widget> actions;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final Widget? trailing;
  final Color? color;
  final bool border;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final bool hasHeader = title != null || subtitle != null || actions.isNotEmpty || trailing != null;
    return Container(
      margin: margin,
      height: height,
      decoration: BoxDecoration(
        color: color ?? AppColors.card,
        borderRadius: AppRadius.lgAll,
        border: border ? Border.all(color: AppColors.border) : null,
        boxShadow: AppColors.cardShadow,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (hasHeader) ...<Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.sm + 2,
                AppSpacing.sm,
                AppSpacing.sm,
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        if (title != null)
                          Text(
                            title!,
                            style: AppTypography.subtitle.copyWith(fontSize: 14),
                            overflow: TextOverflow.ellipsis,
                          ),
                        if (subtitle != null)
                          Text(
                            subtitle!,
                            style: AppTypography.caption.copyWith(
                              color: AppColors.textSecondary,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  ...actions,
                  if (trailing != null) trailing!,
                ],
              ),
            ),
            const Divider(height: 1, color: AppColors.divider),
          ],
          Padding(padding: padding, child: child),
        ],
      ),
    );
  }
}

/// Encabezado de módulo: título, subtítulo y acciones alineadas a la derecha.
///
/// Es la primera pieza de cada pantalla principal (Ventas, Inventario,
/// Clientes, Caja, Reportes, Configuración). Mantiene la misma altura en todos
/// los módulos para que el cambio de sección no produzca saltos visuales.
class ModuleHeader extends StatelessWidget {
  const ModuleHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const <Widget>[],
    this.icon,
  });

  final String title;
  final String? subtitle;
  final List<Widget> actions;

  /// Icono opcional a la izquierda del título (marca del módulo).
  final IconData? icon;

  /// Alto reservado al encabezado para que no haya saltos entre módulos.
  static const double height = 44;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: height,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            if (icon != null) ...<Widget>[
              Icon(icon, size: 20, color: AppColors.deepBlue),
              const SizedBox(width: AppSpacing.sm),
            ],
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    style: AppTypography.headline.copyWith(fontSize: 17),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      style: AppTypography.caption.copyWith(
                        color: AppColors.textSecondary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            if (actions.isNotEmpty) ...<Widget>[
              const SizedBox(width: AppSpacing.md),
              Flexible(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  reverse: true,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: actions,
                  ),
                ),
              ),
            ],
          ],
        ),
      );
}

/// Etiqueta de sección (mayúsculas pequeñas, azul profundo).
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.xs),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                text.toUpperCase(),
                style: AppTypography.label.copyWith(color: AppColors.textSecondary),
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      );
}

/// Importe monetario con cifras tabulares (se alinean en columnas).
class MoneyText extends StatelessWidget {
  const MoneyText(
    this.value, {
    super.key,
    this.currency = const CurrencyFormat(),
    this.size,
    this.weight,
    this.color,
    this.showSign = false,
  });

  final Money value;
  final CurrencyFormat currency;
  final double? size;
  final FontWeight? weight;
  final Color? color;

  /// Muestra `+` en importes positivos (variaciones, arqueos).
  final bool showSign;

  @override
  Widget build(BuildContext context) {
    final CurrencyFormat fmt = currency;
    final String text = showSign && value.isPositive ? '+${fmt.money(value)}' : fmt.money(value);
    return Text(
      text,
      style: AppTypography.table.copyWith(
        fontSize: size,
        fontWeight: weight ?? FontWeight.w600,
        color: color ??
            (value.isNegative ? AppColors.red : AppColors.textPrimary),
        fontFeatures: AppTypography.tabularFigures,
      ),
    );
  }
}

/// Botón principal (naranja = confirmar/cobrar).
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.large = false,
    this.expand = false,
    this.shortcut,
    this.color,
    this.tooltip,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool large;
  final bool expand;
  final String? shortcut;
  final Color? color;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final Color background = color ?? AppColors.orange;
    final Widget button = SizedBox(
      height: large ? 56 : AppSpacing.controlHeight,
      width: expand ? double.infinity : null,
      child: DecoratedBox(
        decoration: large && onPressed != null
            ? BoxDecoration(
                boxShadow: AppColors.accentShadow,
                borderRadius: AppRadius.mdAll,
              )
            : const BoxDecoration(),
        child: ElevatedButton(
          onPressed: onPressed,
          style: ElevatedButton.styleFrom(
            backgroundColor: background,
            foregroundColor: AppColors.white,
            disabledBackgroundColor: AppColors.grey300,
            disabledForegroundColor: AppColors.grey500,
            padding: EdgeInsets.symmetric(horizontal: large ? AppSpacing.md : AppSpacing.md),
            elevation: 0,
            shape: const RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
            textStyle: large ? AppTypography.buttonLarge : AppTypography.button,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Icon(icon, size: large ? 22 : 17),
                const SizedBox(width: AppSpacing.sm),
              ],
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: large ? AppTypography.buttonLarge : AppTypography.button,
                ),
              ),
              if (shortcut != null) ...<Widget>[
                const SizedBox(width: AppSpacing.sm),
                _ShortcutBadge(shortcut!),
              ],
            ],
          ),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// Botón secundario (cian, contorno).
class SecondaryButton extends StatelessWidget {
  const SecondaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.expand = false,
    this.textOnly = false,
    this.shortcut,
    this.tooltip,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool expand;
  final bool textOnly;
  final String? shortcut;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final Widget content = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        if (icon != null) ...<Widget>[
          Icon(icon, size: 17),
          const SizedBox(width: AppSpacing.xs + 2),
        ],
        Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
        if (shortcut != null) ...<Widget>[
          const SizedBox(width: AppSpacing.xs + 2),
          _ShortcutBadge(shortcut!),
        ],
      ],
    );

    final Widget button = SizedBox(
      height: AppSpacing.controlHeight,
      width: expand ? double.infinity : null,
      child: textOnly
          ? TextButton(
              onPressed: onPressed,
              style: TextButton.styleFrom(foregroundColor: AppColors.cyanDark),
              child: content,
            )
          : OutlinedButton(
              onPressed: onPressed,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.cyanDark,
                side: const BorderSide(color: AppColors.cyan),
                shape: const RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
              ),
              child: content,
            ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// Botón de peligro (anular, eliminar).
class DangerButton extends StatelessWidget {
  const DangerButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon = Icons.delete_outline,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData icon;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: AppSpacing.controlHeight,
        child: OutlinedButton.icon(
          onPressed: onPressed,
          icon: Icon(icon, size: 17),
          label: Text(label),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.red,
            side: const BorderSide(color: AppColors.red),
            shape: const RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
          ),
        ),
      );
}

/// Aviso compacto en línea (advertencias de stock, sincronización, etc.).
class InlineBanner extends StatelessWidget {
  const InlineBanner({
    super.key,
    required this.message,
    this.icon = Icons.info_outline,
    this.color = AppColors.cyan,
    this.background,
    this.actions = const <Widget>[],
  });

  final String message;
  final IconData icon;
  final Color color;
  final Color? background;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: background ?? color.withValues(alpha: 0.10),
          borderRadius: AppRadius.mdAll,
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 18, color: color),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                message,
                style: AppTypography.caption.copyWith(
                  color: AppColors.textPrimary,
                  fontSize: 12,
                ),
              ),
            ),
            ...actions,
          ],
        ),
      );
}

/// Estado vacío (sin resultados, sin ventas, sin movimientos).
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.title,
    this.message,
    this.icon = Icons.inbox_outlined,
    this.action,
  });

  final String title;
  final String? message;
  final IconData icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: AppColors.grey100,
                  borderRadius: BorderRadius.circular(36),
                ),
                child: Icon(icon, size: 34, color: AppColors.grey400),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(title, style: AppTypography.subtitle),
              if (message != null) ...<Widget>[
                const SizedBox(height: AppSpacing.xs),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Text(
                    message!,
                    textAlign: TextAlign.center,
                    style: AppTypography.caption.copyWith(color: AppColors.textSecondary),
                  ),
                ),
              ],
              if (action != null) ...<Widget>[
                const SizedBox(height: AppSpacing.lg),
                action!,
              ],
            ],
          ),
        ),
      );
}

/// Indicador de carga con contexto.
class LoadingState extends StatelessWidget {
  const LoadingState({super.key, this.message = 'Cargando…'});

  final String message;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(strokeWidth: 2.6),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              message,
              style: AppTypography.caption.copyWith(color: AppColors.textSecondary),
            ),
          ],
        ),
      );
}

/// Estado de error con reintento.
class ErrorState extends StatelessWidget {
  const ErrorState({
    super.key,
    required this.message,
    this.onRetry,
    this.icon = Icons.error_outline,
  });

  final String message;
  final VoidCallback? onRetry;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 34, color: AppColors.red),
              const SizedBox(height: AppSpacing.sm),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Text(
                  message,
                  textAlign: TextAlign.center,
                  style: AppTypography.body,
                ),
              ),
              if (onRetry != null) ...<Widget>[
                const SizedBox(height: AppSpacing.md),
                SecondaryButton(label: 'Reintentar', icon: Icons.refresh, onPressed: onRetry),
              ],
            ],
          ),
        ),
      );
}

/// Tarjeta de indicador (panel de reportes y barra lateral).
class KpiCard extends StatelessWidget {
  const KpiCard({
    super.key,
    required this.label,
    required this.value,
    this.icon,
    this.color = AppColors.cyan,
    this.hint,
    this.onTap,
    this.trendBps,
  });

  final String label;
  final String value;
  final IconData? icon;
  final Color color;
  final String? hint;
  final VoidCallback? onTap;

  /// Variación porcentual (basis points) frente al período anterior.
  ///
  /// Positivo = creció. Cero/nulo = no se muestra.
  final int? trendBps;

  @override
  Widget build(BuildContext context) {
    final Widget card = Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: AppRadius.lgAll,
        border: Border.all(color: AppColors.border),
        boxShadow: AppColors.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: AppRadius.smAll,
                  ),
                  child: Icon(icon, size: 16, color: color),
                ),
                const SizedBox(width: AppSpacing.sm),
              ],
              Expanded(
                child: Text(
                  label.toUpperCase(),
                  style: AppTypography.label.copyWith(color: AppColors.textSecondary),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (trendBps != null && trendBps != 0)
                Row(
                  children: <Widget>[
                    Icon(
                      trendBps! > 0 ? Icons.trending_up : Icons.trending_down,
                      size: 14,
                      color: trendBps! > 0 ? AppColors.success : AppColors.red,
                    ),
                    const SizedBox(width: 2),
                    Text(
                      '${(trendBps!.abs() / 100).toStringAsFixed(1)}%',
                      style: AppTypography.caption.copyWith(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        color: trendBps! > 0 ? AppColors.success : AppColors.red,
                      ),
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: AppTypography.display.copyWith(fontSize: 22),
              maxLines: 1,
            ),
          ),
          if (hint != null) ...<Widget>[
            const SizedBox(height: 2),
            Text(
              hint!,
              style: AppTypography.caption.copyWith(color: AppColors.textSecondary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
    if (onTap == null) return card;
    return InkWell(
      onTap: onTap,
      borderRadius: AppRadius.lgAll,
      child: card,
    );
  }
}

/// Etiqueta de estado con color semántico.
class StatusChip extends StatelessWidget {
  const StatusChip({
    super.key,
    required this.label,
    this.color = AppColors.cyan,
    this.icon,
    this.filled = false,
  });

  final String label;
  final Color color;
  final IconData? icon;
  final bool filled;

  factory StatusChip.forSaleStatus(SaleStatus status) => StatusChip(
        label: status.label,
        color: switch (status) {
          SaleStatus.completed => AppColors.success,
          SaleStatus.held => AppColors.orange,
          SaleStatus.voided => AppColors.red,
          SaleStatus.refunded => AppColors.warning,
        },
      );

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 2),
        decoration: BoxDecoration(
          color: filled ? color : color.withValues(alpha: 0.12),
          borderRadius: AppRadius.pillAll,
          border: Border.all(color: color.withValues(alpha: filled ? 1 : 0.35)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (icon != null) ...<Widget>[
              Icon(icon, size: 12, color: filled ? AppColors.white : color),
              const SizedBox(width: 3),
            ],
            Text(
              label,
              style: AppTypography.caption.copyWith(
                color: filled ? AppColors.white : color,
                fontWeight: FontWeight.w600,
                fontSize: 11,
              ),
            ),
          ],
        ),
      );
}

/// Diálogo de confirmación con lenguaje claro.
///
/// Se exige confirmación explícita en acciones destructivas (anular venta,
/// borrar producto, cerrar caja): un POS se opera con prisa y un clic de más no
/// debe destruir información.
class ConfirmDialog extends StatelessWidget {
  const ConfirmDialog({
    super.key,
    required this.title,
    required this.message,
    this.confirmLabel = 'Confirmar',
    this.cancelLabel = 'Cancelar',
    this.destructive = false,
    this.requireText,
    this.extra,
  });

  final String title;
  final String message;
  final String confirmLabel;
  final String cancelLabel;
  final bool destructive;

  /// Texto que el usuario debe escribir para confirmar (operaciones críticas).
  final String? requireText;
  final Widget? extra;

  static Future<bool> show(
    BuildContext context, {
    required String title,
    required String message,
    String confirmLabel = 'Confirmar',
    bool destructive = false,
    String? requireText,
    Widget? extra,
  }) async {
    final bool? result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) => ConfirmDialog(
        title: title,
        message: message,
        confirmLabel: confirmLabel,
        destructive: destructive,
        requireText: requireText,
        extra: extra,
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final Color accent = destructive ? AppColors.red : AppColors.orange;
    return _ConfirmDialogBody(
      title: title,
      message: message,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel,
      destructive: destructive,
      requireText: requireText,
      extra: extra,
      accent: accent,
    );
  }
}

class _ConfirmDialogBody extends StatefulWidget {
  const _ConfirmDialogBody({
    required this.title,
    required this.message,
    required this.confirmLabel,
    required this.cancelLabel,
    required this.destructive,
    required this.accent,
    this.requireText,
    this.extra,
  });

  final String title;
  final String message;
  final String confirmLabel;
  final String cancelLabel;
  final bool destructive;
  final Color accent;
  final String? requireText;
  final Widget? extra;

  @override
  State<_ConfirmDialogBody> createState() => _ConfirmDialogBodyState();
}

class _ConfirmDialogBodyState extends State<_ConfirmDialogBody> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.requireText == null ? widget.requireText : '');
  bool _matches = false;

  @override
  void initState() {
    super.initState();
    _matches = widget.requireText == null;
    _controller.addListener(() {
      final bool matches = widget.requireText == null ||
          _controller.text.trim().toUpperCase() == widget.requireText!.toUpperCase();
      if (matches != _matches) setState(() => _matches = matches);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        icon: Icon(
          widget.destructive ? Icons.warning_amber_rounded : Icons.help_outline,
          color: widget.accent,
        ),
        title: Text(widget.title),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(widget.message, style: AppTypography.body),
              if (widget.extra != null) ...<Widget>[
                const SizedBox(height: AppSpacing.md),
                widget.extra!,
              ],
              if (widget.requireText != null) ...<Widget>[
                const SizedBox(height: AppSpacing.md),
                Text(
                  'Escriba ${widget.requireText} para confirmar:',
                  style: AppTypography.caption.copyWith(color: AppColors.red),
                ),
                const SizedBox(height: AppSpacing.xs),
                TextField(
                  controller: _controller,
                  autofocus: true,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(hintText: 'Confirmación'),
                ),
              ],
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(widget.cancelLabel),
          ),
          ElevatedButton(
            onPressed:
                _matches ? () => Navigator.of(context).pop(true) : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: widget.destructive ? AppColors.red : AppColors.orange,
              foregroundColor: AppColors.white,
            ),
            child: Text(widget.confirmLabel),
          ),
        ],
      );
}

/// Aviso flotante (éxito, advertencia, error) con el estilo de la aplicación.
abstract final class AppSnack {
  static void success(BuildContext context, String message) => _show(
        context,
        message: message,
        color: AppColors.success,
        icon: Icons.check_circle_outline,
      );

  static void info(BuildContext context, String message) => _show(
        context,
        message: message,
        color: AppColors.cyan,
        icon: Icons.info_outline,
      );

  static void warning(BuildContext context, String message) => _show(
        context,
        message: message,
        color: AppColors.orange,
        icon: Icons.warning_amber_outlined,
      );

  static void error(BuildContext context, String message) => _show(
        context,
        message: message,
        color: AppColors.red,
        icon: Icons.error_outline,
        duration: const Duration(seconds: 8),
      );

  static void _show(
    BuildContext context, {
    required String message,
    required Color color,
    required IconData icon,
    Duration duration = const Duration(seconds: 4),
  }) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          duration: duration,
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppColors.deepBlueDark,
          width: 560,
          content: Row(
            children: <Widget>[
              Icon(icon, color: color, size: 18),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  message,
                  style: AppTypography.body.copyWith(
                    color: AppColors.white,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
  }
}

/// Aviso de atajo de teclado.
class _ShortcutBadge extends StatelessWidget {
  const _ShortcutBadge(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        decoration: BoxDecoration(
          color: AppColors.white.withValues(alpha: 0.16),
          borderRadius: AppRadius.xsAll,
        ),
        child: Text(
          text,
          style: AppTypography.shortcut.copyWith(
            color: AppColors.white,
            fontSize: 9.5,
          ),
        ),
      );
}

/// Fila de la tabla de resultados con selección por teclado.
class DataRowTile extends StatelessWidget {
  const DataRowTile({
    super.key,
    required this.cells,
    this.flex = const <int>[],
    this.selected = false,
    this.onTap,
    this.color,
    this.height = 40,
  });

  final List<Widget> cells;
  final List<int> flex;
  final bool selected;
  final VoidCallback? onTap;
  final Color? color;
  final double height;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Container(
          height: height,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.cyanSurface
                : (color ?? Colors.transparent),
            border: const Border(
              bottom: BorderSide(color: AppColors.grey100),
            ),
          ),
          child: Row(
            children: <Widget>[
              for (int i = 0; i < cells.length; i++)
                Expanded(flex: flex.length > i ? flex[i] : 1, child: cells[i]),
            ],
          ),
        ),
      );
}

/// Mensaje de ayuda en línea (barra de estado y diálogos).
class HintText extends StatelessWidget {
  const HintText(this.text, {super.key, this.icon = Icons.lightbulb_outline});

  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Row(
        children: <Widget>[
          Icon(icon, size: 14, color: AppColors.cyanDark),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              text,
              style: AppTypography.caption.copyWith(color: AppColors.textSecondary),
            ),
          ),
        ],
      );
}

/// Campo de texto de una sola línea con etiqueta (formularios de configuración).
class LabeledField extends StatelessWidget {
  const LabeledField({
    super.key,
    required this.label,
    required this.child,
    this.helper,
    this.width,
  });

  final String label;
  final Widget child;
  final String? helper;
  final double? width;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(label, style: AppTypography.label.copyWith(color: AppColors.textSecondary)),
            const SizedBox(height: 4),
            child,
            if (helper != null) ...<Widget>[
              const SizedBox(height: 3),
              Text(
                helper!,
                style: AppTypography.caption.copyWith(
                  color: AppColors.textHint,
                  fontSize: 11,
                ),
              ),
            ],
          ],
        ),
      );
}

/// Envoltorio de teclado: captura atajos de función (F1…F12) sin robarlos a
/// los campos de texto cuando el usuario está escribiendo.
class ShortcutScope extends StatelessWidget {
  const ShortcutScope({
    super.key,
    required this.bindings,
    required this.child,
  });

  /// Atajo -> acción. La clave es el valor de `LogicalKeyboardKey.keyF1`, etc.
  final Map<LogicalKeyboardKey, VoidCallback> bindings;
  final Widget child;

  @override
  Widget build(BuildContext context) => Shortcuts(
        shortcuts: <ShortcutActivator, Intent>{
          for (final MapEntry<LogicalKeyboardKey, VoidCallback> entry in bindings.entries)
            SingleActivator(entry.key): _CallbackIntent(entry.value),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            _CallbackIntent: _CallbackAction(),
          },
          child: Focus(autofocus: true, child: child),
        ),
      );
}

class _CallbackIntent extends Intent {
  const _CallbackIntent(this.callback);

  final VoidCallback callback;
}

class _CallbackAction extends Action<_CallbackIntent> {
  @override
  void invoke(covariant _CallbackIntent intent) => intent.callback();
}

/// Texto secundario estándar.
Widget hint(String text) =>
    Text(text, style: AppTypography.caption.copyWith(color: AppColors.textSecondary));
