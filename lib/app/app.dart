import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/app_config.dart';
import '../core/theme/app_theme.dart';
import '../features/auth/presentation/login_screen.dart';
import '../features/auth/application/session_controller.dart';
import 'shell/app_shell.dart';

/// Raíz de la aplicación.
///
/// Dos únicos estados posibles: **sesión abierta** (shell con los módulos) o
/// **sesión cerrada** (pantalla de acceso por PIN). Todo lo demás son diálogos
/// dentro del shell, lo que evita perder el contexto del trabajo del cajero.
class UltraPosApp extends ConsumerWidget {
  const UltraPosApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final SessionState session = ref.watch(sessionProvider);

    return MaterialApp(
      title: AppConfig.windowTitle,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      locale: const Locale('es'),
      builder: (BuildContext context, Widget? child) => _GlobalShortcuts(
        child: child ?? const SizedBox.shrink(),
      ),
      home: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        child: session.isAuthenticated
            ? const AppShell(key: ValueKey<String>('shell'))
            : const LoginScreen(key: ValueKey<String>('login')),
      ),
    );
  }
}

/// Atajos válidos en toda la aplicación (no dependen del módulo activo).
class _GlobalShortcuts extends StatelessWidget {
  const _GlobalShortcuts({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Shortcuts(
        shortcuts: const <ShortcutActivator, Intent>{
          // F11 alterna pantalla completa (comportamiento esperado en Windows).
          SingleActivator(LogicalKeyboardKey.f11): _ToggleFullScreenIntent(),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            _ToggleFullScreenIntent: CallbackAction<_ToggleFullScreenIntent>(
              onInvoke: (_) {
                // El alternado real lo hace el sistema de ventanas; aquí solo
                // se deja el gancho para no bloquear la tecla.
                return null;
              },
            ),
          },
          child: Focus(autofocus: true, child: child),
        ),
      );
}

class _ToggleFullScreenIntent extends Intent {
  const _ToggleFullScreenIntent();
}
