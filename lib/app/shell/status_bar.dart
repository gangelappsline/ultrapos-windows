import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../core/database/daos/cash_dao.dart';
import '../../core/domain/enums.dart';
import '../../core/hardware/printer_config.dart';
import '../../core/providers.dart';
import '../../core/sync/sync_models.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/ui/app_widgets.dart';
import '../../core/utils/formatters.dart';

/// Barra de estado inferior.
///
/// Es el "tablero de instrumentos" de la caja: sincronización, turno de caja,
/// impresora, usuario y reloj. Un cajero debe poder saber el estado del sistema
/// **sin salir de la pantalla de venta**; esconder esa información en un menú es
/// la causa habitual de "no me di cuenta de que estaba sin internet".
class StatusBar extends ConsumerStatefulWidget {
  const StatusBar({super.key});

  @override
  ConsumerState<StatusBar> createState() => _StatusBarState();
}

class _StatusBarState extends ConsumerState<StatusBar> {
  Timer? _clock;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(AppDurations.clockTick, (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final SyncStatusSnapshot sync =
        ref.watch(syncStatusProvider).value ?? SyncStatusSnapshot.idle;
    final CashSession? session = ref.watch(cashSessionProvider).value;
    final PrinterConfig? printer = ref.watch(printerConfigProvider).value;

    return Container(
      height: AppSpacing.statusBarHeight,
      decoration: const BoxDecoration(
        color: AppColors.deepBlue,
        border: Border(
          top: BorderSide(color: AppColors.deepBlueDark),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
      child: Row(
        children: <Widget>[
          _StatusItem(
            icon: sync.isOnline ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
            label: sync.label,
            color: _syncColor(sync),
            tooltip: _syncTooltip(sync),
            onTap: () => ref.read(syncServiceProvider).syncNow(manual: true).ignore(),
          ),
          _Separator(),
          _StatusItem(
            icon: session == null ? Icons.lock_outline : Icons.lock_open_outlined,
            label: session == null
                ? 'Caja cerrada'
                : 'Turno abierto · ${AppFormat.clock(session.openedAt)}',
            color: session == null ? AppColors.orangeLight : AppColors.successSurface,
            tooltip: session == null
                ? 'No hay un turno de caja abierto. Ábralo en el módulo Caja.'
                : 'Turno de ${session.openedByName} · fondo inicial '
                    '${CurrencyFormat().money(session.openingAmount)}',
            onTap: () => _goTo(AppSection.cash),
          ),
          _Separator(),
          _StatusItem(
            icon: _printerIcon(printer),
            label: printer?.destinationLabel ?? 'Sin impresora',
            color: printer?.isUsable ?? false ? AppColors.white70 : AppColors.orangeLight,
            tooltip: _printerTooltip(printer),
            onTap: () => _goTo(AppSection.settings),
          ),
          const Spacer(),
          if (sync.needsAttention)
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.sm),
              child: StatusChip(
                label: '${sync.failedCount} con error',
                color: AppColors.red,
                icon: Icons.error_outline,
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.sm),
            child: Text(
              'v${AppConfig.appVersion}',
              style: AppTypography.caption.copyWith(
                color: AppColors.white38,
                fontSize: 10,
              ),
            ),
          ),
          _Separator(),
          Padding(
            padding: const EdgeInsets.only(left: AppSpacing.sm),
            child: Text(
              '${AppFormat.clock(_now)}',
              style: AppTypography.caption.copyWith(
                color: AppColors.white70,
                fontSize: 11,
                fontFeatures: AppTypography.tabularFigures,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _goTo(AppSection section) {
    // Se importa el proveedor de sección de forma diferida para no crear un
    // ciclo de importaciones entre la barra de estado y el shell.
    _navigate(context, section);
  }

  Color _syncColor(SyncStatusSnapshot sync) {
    if (!sync.isOnline) return AppColors.orangeLight;
    if (sync.failedCount > 0) return AppColors.red;
    if (sync.hasPending) return AppColors.cyanLight;
    return AppColors.successSurface;
  }

  String _syncTooltip(SyncStatusSnapshot sync) => <String>[
        sync.label,
        if (sync.lastSyncAt != null)
          'Última sincronización: ${AppFormat.time(sync.lastSyncAt!)}',
        if (sync.pendingCount > 0) 'Pendientes: ${sync.pendingCount}',
        if (sync.lastError != null) 'Error: ${sync.lastError}',
        'Clic para sincronizar ahora',
      ].join('\n');

  static IconData _printerIcon(PrinterConfig? config) {
    if (config == null || !config.isUsable) return Icons.print_disabled_outlined;
    return switch (config.type) {
      PrinterType.network => Icons.wifi,
      PrinterType.serial => Icons.cable,
      PrinterType.pdf => Icons.picture_as_pdf_outlined,
      PrinterType.windowsSpool => Icons.print_outlined,
      PrinterType.none => Icons.print_disabled_outlined,
    };
  }

  String _printerTooltip(PrinterConfig? config) {
    if (config == null) return 'Configuración de impresora no disponible';
    return <String>[
      config.type.label,
      'Destino: ${config.destinationLabel}',
      'Papel: ${config.paperWidth.millimeters} mm',
      'Cajón: ${config.drawer.label}',
    ].join('\n');
  }
}

/// Puente hacia el shell (evita dependencias circulares entre archivos).
void _navigate(BuildContext context, AppSection section) {
  SectionNavigator.of(context)?.go(section);
}

/// Permite a los hijos del shell cambiar de sección sin importar el shell.
class SectionNavigator extends InheritedWidget {
  const SectionNavigator({
    super.key,
    required this.go,
    required super.child,
  });

  final void Function(AppSection section) go;

  static SectionNavigator? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SectionNavigator>();

  @override
  bool updateShouldNotify(SectionNavigator oldWidget) => false;
}

/// Elemento de la barra de estado.
class _StatusItem extends StatelessWidget {
  const _StatusItem({
    required this.icon,
    required this.label,
    required this.color,
    this.tooltip,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final String? tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final Widget content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: AppTypography.caption.copyWith(
              color: AppColors.white90,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );

    return Tooltip(
      message: tooltip ?? label,
      waitDuration: const Duration(milliseconds: 400),
      child: onTap == null
          ? content
          : InkWell(
              onTap: onTap,
              child: content,
            ),
    );
  }
}

class _Separator extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
        width: 1,
        height: 14,
        margin: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
        color: AppColors.white24,
      );
}
