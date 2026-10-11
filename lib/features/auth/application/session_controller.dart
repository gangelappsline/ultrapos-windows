import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/daos/settings_dao.dart';
import '../../../core/domain/enums.dart';
import '../../../core/logging/app_logger.dart';
import '../../../core/providers.dart';

/// Claves de configuración de la sesión (nunca se sincronizan a la nube).
abstract final class SessionKeys {
  static const String lastUserUuid = 'session.last_user_uuid';
  static const String lastLoginAt = 'session.last_login_at';
  static const String autoLogin = 'session.auto_login';
}

/// Estado de la sesión de trabajo.
@immutable
class SessionState {
  const SessionState({
    this.user,
    this.loginAt,
    this.failedAttempts = 0,
    this.lastError,
    this.isRestoring = true,
  });

  final User? user;
  final DateTime? loginAt;
  final int failedAttempts;
  final String? lastError;

  /// Mientras se restaura la sesión guardada no se debe mostrar la pantalla de
  /// acceso (evita un parpadeo molesto al abrir la aplicación).
  final bool isRestoring;

  bool get isAuthenticated => user != null;

  bool get isLocked => failedAttempts >= 5;

  UserRole get role => user?.role ?? UserRole.cashier;

  String get displayName => user?.fullName ?? 'Sin sesión';

  int get sessionMinutes =>
      loginAt == null ? 0 : DateTime.now().difference(loginAt!).inMinutes;

  SessionState copyWith({
    User? user,
    DateTime? loginAt,
    int? failedAttempts,
    String? lastError,
    bool? isRestoring,
    bool clearUser = false,
    bool clearError = false,
  }) =>
      SessionState(
        user: clearUser ? null : (user ?? this.user),
        loginAt: clearUser ? null : (loginAt ?? this.loginAt),
        failedAttempts: failedAttempts ?? this.failedAttempts,
        lastError: clearError ? null : (lastError ?? this.lastError),
        isRestoring: isRestoring ?? this.isRestoring,
      );
}

/// Control de la sesión: acceso por PIN, bloqueo por intentos y cierre.
///
/// El PIN nunca se compara aquí: se delega en `UsersDao.authenticateWithPin`,
/// que usa PBKDF2 con sal aleatoria y comparación en tiempo constante. Este
/// controlador solo decide **cuándo** se permite intentar y qué se audita.
class SessionController extends Notifier<SessionState> {
  static const String _scope = 'session';

  @override
  SessionState build() {
    // Restauración diferida: `build` debe ser síncrono.
    Future<void>.microtask(_restore);
    return const SessionState();
  }

  Future<void> _restore() async {
    try {
      final SettingsDao settings = ref.read(appDatabaseProvider).settingsDao;
      final bool autoLogin =
          await settings.boolValue(SessionKeys.autoLogin, fallback: false);
      final String? uuid = await settings.rawValue(SessionKeys.lastUserUuid);

      if (!autoLogin || uuid == null || uuid.isEmpty) {
        state = state.copyWith(isRestoring: false);
        return;
      }

      final User? user = await ref.read(appDatabaseProvider).usersDao.findByUuid(uuid);
      if (user == null || !user.isActive) {
        state = state.copyWith(isRestoring: false, clearUser: true);
        return;
      }

      state = state.copyWith(
        user: user,
        loginAt: DateTime.now(),
        isRestoring: false,
        failedAttempts: 0,
      );
      Log.info(_scope, 'Sesión restaurada: ${user.fullName}');
    } on Object catch (error) {
      Log.warning(_scope, 'No se pudo restaurar la sesión: $error');
      state = state.copyWith(isRestoring: false);
    }
  }

  /// Intenta iniciar sesión con [pin]. Devuelve `true` si fue correcto.
  Future<bool> login(String pin) async {
    if (state.isLocked) {
      state = state.copyWith(lastError: 'Equipo bloqueado por intentos fallidos.');
      return false;
    }

    final AppDatabase database = ref.read(appDatabaseProvider);
    try {
      final User? user = await database.usersDao.authenticateWithPin(pin);

      if (user == null) {
        final int attempts = state.failedAttempts + 1;
        state = state.copyWith(
          failedAttempts: attempts,
          lastError: attempts >= 5
              ? 'Demasiados intentos fallidos. El equipo quedó bloqueado.'
              : 'PIN incorrecto. Intente de nuevo.',
        );
        await database.recordAudit(
          entity: 'session',
          entityUuid: 'login',
          action: 'login_failed',
          note: 'Intento fallido $attempts',
        );
        return false;
      }

      await database.usersDao.recordLogin(user.id);
      await database.settingsDao.setValue(
        SessionKeys.lastUserUuid,
        user.uuid,
        syncToCloud: false,
      );
      await database.settingsDao.setValue(
        SessionKeys.lastLoginAt,
        DateTime.now().toIso8601String(),
        syncToCloud: false,
      );
      await database.recordAudit(
        entity: 'session',
        entityUuid: user.uuid,
        action: 'login',
        userId: user.uuid,
        userName: user.fullName,
        note: 'Acceso correcto (${user.role.label})',
      );

      state = SessionState(
        user: user,
        loginAt: DateTime.now(),
        isRestoring: false,
      );
      Log.info(_scope, 'Acceso: ${user.fullName} (${user.role.storageKey})');
      return true;
    } on Object catch (error) {
      Log.error(_scope, 'Error al iniciar sesión', error: error);
      state = state.copyWith(lastError: 'No se pudo verificar el PIN.');
      return false;
    }
  }

  /// Cierra la sesión actual (deja la caja como está: un turno abierto sigue
  /// abierto, porque el dinero está físicamente en el cajón).
  Future<void> logout({String? reason}) async {
    final User? user = state.user;
    final AppDatabase database = ref.read(appDatabaseProvider);

    if (user != null) {
      await database.recordAudit(
        entity: 'session',
        entityUuid: user.uuid,
        action: 'logout',
        userId: user.uuid,
        userName: user.fullName,
        note: reason ?? 'Cierre de sesión',
      );
    }

    state = const SessionState(isRestoring: false);
    Log.info(_scope, 'Sesión cerrada: ${reason ?? 'manual'}');
  }

  /// Autoriza una acción sensible (anular venta, descuento alto) sin cambiar de
  /// usuario: el supervisor pone su PIN y la venta continúa a nombre del cajero.
  Future<User?> authorizeSupervisor(String pin) async {
    final User? authorizer = await ref
        .read(appDatabaseProvider)
        .usersDao
        .authorizeWithPin(pin, minimumRole: UserRole.supervisor);
    if (authorizer == null) return null;

    await ref.read(appDatabaseProvider).recordAudit(
          entity: 'session',
          entityUuid: authorizer.uuid,
          action: 'authorize',
          userId: authorizer.uuid,
          userName: authorizer.fullName,
          note: 'Autorización de supervisor',
        );
    return authorizer;
  }

  /// Activa/desactiva el acceso automático para este equipo de caja.
  Future<void> setAutoLogin(bool value) async {
    await ref.read(appDatabaseProvider).settingsDao.setValue(
          SessionKeys.autoLogin,
          value,
          syncToCloud: false,
        );
  }

  /// Limpia el contador de intentos fallidos (lo usa un administrador).
  void unlock() => state = state.copyWith(failedAttempts: 0, clearError: true);
}

final sessionProvider = NotifierProvider<SessionController, SessionState>(
  SessionController.new,
);

/// Usuario autenticado (atajo de lectura para pantallas y servicios).
final currentUserProvider = Provider<User?>(
  (Ref ref) => ref.watch(sessionProvider).user,
);
