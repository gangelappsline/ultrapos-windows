import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../core/database/daos/cash_dao.dart';
import '../../core/domain/enums.dart';
import '../../core/providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/ui/app_widgets.dart';
import '../../features/auth/application/session_controller.dart';
import '../../features/cash/presentation/cash_screen.dart';
import '../../features/customers/presentation/customers_screen.dart';
import '../../features/inventory/presentation/inventory_screen.dart';
import '../../features/reports/presentation/reports_screen.dart';
import '../../features/sales/presentation/sales_screen.dart';
import '../../features/settings/presentation/settings_screen.dart';
import 'status_bar.dart';
import 'title_bar.dart';

/// Secciones de la aplicación.
///
/// Cada sección exige un rol mínimo: el POS de una tienda no puede exponer los
/// costos ni la configuración a cualquier cajero, y el propio menú debe reflejar
/// los permisos (una opción que no se puede usar no debe estar visible).
enum AppSection {
  sales('Ventas', Icons.point_of_sale_outlined, Icons.point_of_sale, 'F2', UserRole.cashier),
  inventory('Inventario', Icons.inventory_2_outlined, Icons.inventory_2, 'F3', UserRole.supervisor),
  customers('Clientes', Icons.people_outline, Icons.people, 'F4', UserRole.cashier),
  cash('Caja', Icons.account_balance_wallet_outlined, Icons.account_balance_wallet, 'F5', UserRole.cashier),
  reports('Reportes', Icons.insights_outlined, Icons.insights, 'F6', UserRole.supervisor),
  settings('Configuración', Icons.settings_outlined, Icons.settings, 'F7', UserRole.admin);

  const AppSection(this.label, this.icon, this.activeIcon, this.shortcut, this.minimumRole);

  final String label;
  final IconData icon;
  final IconData activeIcon;
  final String shortcut;
  final UserRole minimumRole;

  bool isAllowedFor(UserRole role) => role.level >= minimumRole.level;
}

/// Sección activa (cambia desde la barra lateral o con atajos).
class ActiveSectionController extends Notifier<AppSection> {
  @override
  AppSection build() => AppSection.sales;

  void go(AppSection section) => state = section;
}

final activeSectionProvider =
    NotifierProvider<ActiveSectionController, AppSection>(ActiveSectionController.new);

/// Shell principal: barra de título + navegación + contenido + barra de estado.
///
/// Es el "marco" que hace que UltraPOS se sienta como software de escritorio:
/// barra de título propia, navegación lateral fija, barra de estado con
/// sincronización/caja/impresora siempre visible y atajos de función activos.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  bool _sidebarCollapsed = false;

  @override
  Widget build(BuildContext context) {
    final AppSection section = ref.watch(activeSectionProvider);
    final SessionState session = ref.watch(sessionProvider);
    final bool compact = MediaQuery.sizeOf(context).width < 1440;

    // Protección de ruta: si el rol del usuario no alcanza para la sección
    // activa (por ejemplo, tras cerrar sesión y entrar como cajero), se vuelve
    // a Ventas en lugar de mostrar una pantalla prohibida.
    if (!section.isAllowedFor(session.role)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref.read(activeSectionProvider.notifier).go(AppSection.sales);
          AppSnack.warning(context, 'No tiene permisos para ${section.label}.');
        }
      });
    }

    final bool collapsed = _sidebarCollapsed || compact && false;

    return SectionNavigator(
      go: (AppSection target) {
        if (!target.isAllowedFor(session.role)) {
          AppSnack.warning(
            context,
            'Se requiere el rol ${target.minimumRole.label} para ${target.label}.',
          );
          return;
        }
        ref.read(activeSectionProvider.notifier).go(target);
      },
      child: _ShellScaffold(
        section: section,
        session: session,
        collapsed: collapsed,
        onToggleSidebar: () => setState(() => _sidebarCollapsed = !_sidebarCollapsed),
      ),
    );
  }
}

/// Cuerpo del shell (separado para poder envolverlo con [SectionNavigator]).
class _ShellScaffold extends ConsumerWidget {
  const _ShellScaffold({
    required this.section,
    required this.session,
    required this.collapsed,
    required this.onToggleSidebar,
  });

  final AppSection section;
  final SessionState session;
  final bool collapsed;
  final VoidCallback onToggleSidebar;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppSection effective =
        section.isAllowedFor(session.role) ? section : AppSection.sales;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        children: <Widget>[
          const WindowTitleBar(),
          Expanded(
            child: Row(
              children: <Widget>[
                _Sidebar(
                  collapsed: collapsed,
                  current: effective,
                  onSelect: (AppSection selected) =>
                      ref.read(activeSectionProvider.notifier).go(selected),
                  onToggle: onToggleSidebar,
                ),
                Expanded(child: _SectionBody(section: effective)),
              ],
            ),
          ),
          const StatusBar(),
        ],
      ),
    );
  }
}

/// Contenido de la sección activa.
class _SectionBody extends StatelessWidget {
  const _SectionBody({required this.section});

  final AppSection section;

  @override
  Widget build(BuildContext context) => switch (section) {
        AppSection.sales => const SalesScreen(),
        AppSection.inventory => const InventoryScreen(),
        AppSection.customers => const CustomersScreen(),
        AppSection.cash => const CashScreen(),
        AppSection.reports => const ReportsScreen(),
        AppSection.settings => const SettingsScreen(),
      };
}

/// Navegación lateral con el logo y los módulos.
class _Sidebar extends ConsumerWidget {
  const _Sidebar({
    required this.collapsed,
    required this.current,
    required this.onSelect,
    required this.onToggle,
  });

  final bool collapsed;
  final AppSection current;
  final ValueChanged<AppSection> onSelect;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final SessionState session = ref.watch(sessionProvider);
    final AsyncValue<CashSession?> openSession = ref.watch(
      cashSessionProvider,
    );

    return AnimatedContainer(
      duration: AppDurations.fast,
      width: collapsed ? AppSpacing.sidebarWidthCompact : AppSpacing.sidebarWidth,
      decoration: const BoxDecoration(
        gradient: AppColors.headerGradient,
      ),
      child: Column(
        children: <Widget>[
          // --- Marca ---
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: collapsed ? AppSpacing.sm : AppSpacing.md,
              vertical: AppSpacing.md,
            ),
            child: Row(
              children: <Widget>[
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    gradient: AppColors.totalGradient,
                    borderRadius: AppRadius.smAll,
                  ),
                  child: const Icon(
                    Icons.point_of_sale,
                    color: AppColors.white,
                    size: 19,
                  ),
                ),
                if (!collapsed) ...<Widget>[
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          AppConfig.appName,
                          style: AppTypography.subtitle.copyWith(
                            color: AppColors.white,
                            fontSize: 15,
                          ),
                        ),
                        Text(
                          'Punto de venta',
                          style: AppTypography.caption.copyWith(
                            color: AppColors.white.withValues(alpha: 0.7),
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.deepBlue600),

          // --- Estado del turno (lo primero que debe ver un cajero) ---
          if (!collapsed)
            Padding(
              padding: const EdgeInsets.all(AppSpacing.sm),
              child: _SessionPill(
                open: openSession.value != null,
                openingAmount: openSession.value?.openingAmount,
              ),
            ),

          // --- Módulos ---
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
              children: <Widget>[
                for (final AppSection section in AppSection.values)
                  if (section.isAllowedFor(session.role))
                    _SidebarItem(
                      section: section,
                      selected: section == current,
                      collapsed: collapsed,
                      onTap: () => onSelect(section),
                    ),
              ],
            ),
          ),

          // --- Usuario y pie ---
          const Divider(height: 1, color: AppColors.deepBlue600),
          InkWell(
            onTap: () => _showUserMenu(context, ref),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.sm),
              child: Row(
                children: <Widget>[
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: AppColors.white.withValues(alpha: 0.12),
                      borderRadius: AppRadius.smAll,
                    ),
                    child: Center(
                      child: Text(
                        _initials(session.user?.fullName ?? '?'),
                        style: AppTypography.caption.copyWith(
                          color: AppColors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  if (!collapsed) ...<Widget>[
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(
                            session.displayName,
                            style: AppTypography.caption.copyWith(
                              color: AppColors.white,
                              fontWeight: FontWeight.w600,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            session.role.label,
                            style: AppTypography.caption.copyWith(
                              color: AppColors.white.withValues(alpha: 0.65),
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Icon(
                      Icons.expand_less,
                      size: 16,
                      color: AppColors.white54,
                    ),
                  ],
                ],
              ),
            ),
          ),
          InkWell(
            onTap: onToggle,
            child: Container(
              height: 30,
              color: AppColors.deepBlueDark.withValues(alpha: 0.35),
              child: Center(
                child: Icon(
                  collapsed ? Icons.chevron_right : Icons.chevron_left,
                  size: 16,
                  color: AppColors.white70,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _initials(String name) {
    final List<String> parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts[1].substring(0, 1)).toUpperCase();
  }

  void _showUserMenu(BuildContext context, WidgetRef ref) {
    showMenu<String>(
      context: context,
      position: const RelativeRect.fromLTRB(24, 600, 400, 24),
      items: <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          enabled: false,
          child: Text(
            '${ref.read(sessionProvider).user?.fullName ?? ''} · '
            '${ref.read(sessionProvider).role.label}',
            style: AppTypography.caption,
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem<String>(value: 'lock', child: Text('Bloquear sesión (Ctrl+L)')),
        const PopupMenuItem<String>(value: 'logout', child: Text('Cerrar sesión')),
      ],
    ).then((String? value) {
      if (value == null) return;
      ref.read(sessionProvider.notifier).logout(reason: value);
    });
  }
}

/// Elemento de la barra lateral.
class _SidebarItem extends StatelessWidget {
  const _SidebarItem({
    required this.section,
    required this.selected,
    required this.collapsed,
    required this.onTap,
  });

  final AppSection section;
  final bool selected;
  final bool collapsed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs, vertical: 1),
        child: Material(
          color: selected ? AppColors.cyan.withValues(alpha: 0.18) : Colors.transparent,
          borderRadius: AppRadius.mdAll,
          child: InkWell(
            onTap: onTap,
            borderRadius: AppRadius.mdAll,
            child: Container(
              height: 38,
              padding: EdgeInsets.symmetric(horizontal: collapsed ? 0 : AppSpacing.sm),
              child: Row(
                mainAxisAlignment:
                    collapsed ? MainAxisAlignment.center : MainAxisAlignment.start,
                children: <Widget>[
                  Icon(
                    selected ? section.activeIcon : section.icon,
                    size: 18,
                    color: selected ? AppColors.cyan : AppColors.white70,
                  ),
                  if (!collapsed) ...<Widget>[
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        section.label,
                        style: AppTypography.body.copyWith(
                          fontSize: 13,
                          color: selected ? AppColors.white : AppColors.white70,
                          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                    ),
                    Text(
                      section.shortcut,
                      style: AppTypography.shortcut.copyWith(
                        color: AppColors.white38,
                        fontSize: 9,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
}

/// Indicador del turno de caja dentro de la barra lateral.
class _SessionPill extends StatelessWidget {
  const _SessionPill({required this.open, this.openingAmount});

  final bool open;
  final Money? openingAmount;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.xs + 2,
        ),
        decoration: BoxDecoration(
          color: open
              ? AppColors.success.withValues(alpha: 0.16)
              : AppColors.orange.withValues(alpha: 0.16),
          borderRadius: AppRadius.mdAll,
          border: Border.all(
            color: open ? AppColors.success : AppColors.orange,
            width: 0.8,
          ),
        ),
        child: Row(
          children: <Widget>[
            Icon(
              open ? Icons.lock_open_outlined : Icons.lock_outline,
              size: 14,
              color: open ? AppColors.successSurface : AppColors.orangeLight,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                open ? 'Caja abierta' : 'Caja cerrada · abra el turno',
                style: AppTypography.caption.copyWith(
                  color: AppColors.white,
                  fontSize: 10.5,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
}
