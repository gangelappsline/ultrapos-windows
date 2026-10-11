import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/config/app_config.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';

/// Barra de título propia.
///
/// Windows nativo, no una imitación: se oculta la barra del sistema
/// (`TitleBarStyle.hidden`) y se dibuja una que respeta la identidad del
/// producto, con los mismos botones (minimizar, maximizar, cerrar) en la misma
/// posición y con los mismos atajos de accesibilidad. La zona central es
/// arrastrable, como en cualquier aplicación de escritorio.
class WindowTitleBar extends StatefulWidget {
  const WindowTitleBar({super.key});

  static const double height = AppSpacing.titleBarHeight;

  @override
  State<WindowTitleBar> createState() => _WindowTitleBarState();
}

class _WindowTitleBarState extends State<WindowTitleBar> with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _syncMaximized();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _syncMaximized() async {
    try {
      final bool maximized = await windowManager.isMaximized();
      if (mounted && maximized != _maximized) {
        setState(() => _maximized = maximized);
      }
    } on Object {
      // Sin gestor de ventanas (entornos de prueba) se ignora.
    }
  }

  @override
  void onWindowMaximize() => setState(() => _maximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _maximized = false);

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => windowManager.startDragging(),
        onDoubleTap: _toggleMaximize,
        child: Container(
          height: WindowTitleBar.height,
          decoration: const BoxDecoration(
            color: AppColors.deepBlueDark,
          ),
          child: Row(
            children: <Widget>[
              const SizedBox(width: AppSpacing.md),
              const Icon(Icons.point_of_sale, size: 15, color: AppColors.cyan),
              const SizedBox(width: AppSpacing.sm),
              Text(
                '${AppConfig.appName} · ${AppConfig.windowSubtitle}',
                style: AppTypography.caption.copyWith(
                  color: AppColors.white70,
                  fontSize: 11.5,
                ),
              ),
              const Spacer(),
              _WindowButton(
                icon: Icons.remove,
                tooltip: 'Minimizar',
                onTap: () => windowManager.minimize(),
              ),
              _WindowButton(
                icon: _maximized ? Icons.filter_none : Icons.crop_square,
                tooltip: _maximized ? 'Restaurar' : 'Maximizar',
                onTap: _toggleMaximize,
              ),
              _WindowButton(
                icon: Icons.close,
                tooltip: 'Cerrar (Alt+F4)',
                danger: true,
                onTap: () => windowManager.close(),
              ),
            ],
          ),
        ),
      );

  Future<void> _toggleMaximize() async {
    try {
      if (await windowManager.isMaximized()) {
        await windowManager.unmaximize();
      } else {
        await windowManager.maximize();
      }
      await _syncMaximized();
    } on Object {
      // Ignorado a propósito: es una acción de conveniencia de la ventana.
    }
  }
}

/// Botón de la barra de título (estilo Windows 11: 46x32 px, sin iconos duros).
class _WindowButton extends StatefulWidget {
  const _WindowButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool danger;

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: widget.tooltip,
        child: MouseRegion(
          cursor: SystemMouseCursors.basic,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            onTap: widget.onTap,
            child: Container(
              width: 46,
              height: WindowTitleBar.height,
              color: _hovered
                  ? (widget.danger ? AppColors.red : AppColors.white12)
                  : Colors.transparent,
              child: Icon(
                widget.icon,
                size: 15,
                color: _hovered && widget.danger ? AppColors.white : AppColors.white70,
              ),
            ),
          ),
        ),
      );
}
