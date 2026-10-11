import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/database/app_database.dart';
import '../../../core/providers.dart';
import '../../../core/security/pin_hasher.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/ui/app_widgets.dart';
import '../../../core/utils/formatters.dart';
import '../application/session_controller.dart';

/// Pantalla de acceso por PIN.
///
/// Un POS se comparte entre varios cajeros y el cambio de turno ocurre con el
/// cliente delante: el acceso debe resolverse en segundos y con una sola mano.
/// Por eso hay teclado numérico en pantalla (pantallas táctiles), se aceptan
/// teclas físicas y se muestra la lista de usuarios activos para elegir con un
/// clic, sin escribir nombres de usuario.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  String _pin = '';
  User? _selected;

  static const int _maxPinLength = 8;

  @override
  Widget build(BuildContext context) {
    final SessionState session = ref.watch(sessionProvider);
    final AsyncValue<List<User>> users = ref.watch(usersProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: KeyboardListener(
        focusNode: FocusNode(debugLabel: 'login-keys'),
        autofocus: true,
        onKeyEvent: _onKey,
        child: Row(
          children: <Widget>[
            // --- Mitad izquierda: identidad de marca ---
            Expanded(
              flex: 5,
              child: Container(
                height: double.infinity,
                decoration: const BoxDecoration(gradient: AppColors.headerGradient),
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.xxl),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          gradient: AppColors.totalGradient,
                          borderRadius: AppRadius.lgAll,
                        ),
                        child: const Icon(
                          Icons.point_of_sale,
                          color: AppColors.white,
                          size: 34,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      Text(
                        AppConfig.appName,
                        style: AppTypography.display.copyWith(
                          fontSize: 40,
                          color: AppColors.white,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        AppConfig.windowSubtitle,
                        style: AppTypography.headline.copyWith(
                          fontSize: 18,
                          color: AppColors.cyanLight,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xl),
                      Text(
                        'Ventas, inventario y caja que siguen funcionando '
                        'aunque se caiga internet.',
                        style: AppTypography.body.copyWith(
                          color: AppColors.white70,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xl),
                      Row(
                        children: <Widget>[
                          const Icon(Icons.cloud_off_outlined, size: 16, color: AppColors.cyanLight),
                          const SizedBox(width: 6),
                          Text(
                            'Operación local garantizada',
                            style: AppTypography.caption.copyWith(color: AppColors.white70),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Row(
                        children: <Widget>[
                          const Icon(Icons.print_outlined, size: 16, color: AppColors.cyanLight),
                          const SizedBox(width: 6),
                          Text(
                            'Impresora térmica y cajón de dinero',
                            style: AppTypography.caption.copyWith(color: AppColors.white70),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // --- Mitad derecha: selección de usuario + PIN ---
            Expanded(
              flex: 4,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Text(
                          _selected == null ? '¿Quién atiende?' : 'Ingrese su PIN',
                          style: AppTypography.title,
                        ),
                        Text(
                          _selected == null
                              ? 'Seleccione su usuario para comenzar el turno'
                              : '${_selected!.fullName} · ${_selected!.role.label}',
                          style: AppTypography.caption,
                        ),
                        const SizedBox(height: AppSpacing.md),

                        if (_selected == null)
                          users.when(
                            data: (List<User> list) => list.isEmpty
                                ? _firstRunCard()
                                : Column(
                                    children: <Widget>[
                                      for (final User user in list)
                                        Padding(
                                          padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                                          child: _UserTile(
                                            user: user,
                                            onTap: () => setState(() {
                                              _selected = user;
                                              _pin = '';
                                            }),
                                          ),
                                        ),
                                    ],
                                  ),
                            error: (Object error, _) => ErrorState(
                              message: 'No se pudo cargar la lista de usuarios: $error',
                            ),
                            loading: () => const LoadingState(),
                          )
                        else ...<Widget>[
                          _PinDisplay(
                            length: _pin.length,
                            maxLength: _maxPinLength,
                            error: session.lastError,
                          ),
                          const SizedBox(height: AppSpacing.md),
                          _NumericKeypad(
                            onDigit: _appendDigit,
                            onBackspace: _backspace,
                            onEnter: _submit,
                            onSubmitLabel: 'Ingresar (Enter)',
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          Row(
                            children: <Widget>[
                              TextButton.icon(
                                onPressed: () => setState(() {
                                  _selected = null;
                                  _pin = '';
                                }),
                                icon: const Icon(Icons.arrow_back, size: 16),
                                label: const Text('Cambiar usuario'),
                              ),
                              const Spacer(),
                              if (session.isLocked)
                                const StatusChip(
                                  label: 'Bloqueado',
                                  color: AppColors.red,
                                  icon: Icons.lock_outline,
                                ),
                            ],
                          ),
                        ],

                        if (session.isLocked) ...<Widget>[
                          const SizedBox(height: AppSpacing.sm),
                          const InlineBanner(
                            message: 'Demasiados intentos fallidos. Solicite a un '
                                'supervisor que desbloquee el equipo.',
                            icon: Icons.lock_outline,
                            color: AppColors.red,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Tarjeta de primer arranque: el equipo aún no tiene usuarios.
  Widget _firstRunCard() => AppCard(
        title: 'Sin usuarios configurados',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'Cree el primer usuario administrador para comenzar a operar. '
              'Se le pedirá un PIN de 4 a 8 dígitos.',
            ),
            const SizedBox(height: AppSpacing.md),
            PrimaryButton(
              label: 'Crear administrador',
              icon: Icons.person_add_alt,
              expand: true,
              onPressed: _createFirstAdmin,
            ),
          ],
        ),
      );

  Future<void> _createFirstAdmin() async {
    final _AdminDraft? draft = await showDialog<_AdminDraft>(
      context: context,
      builder: (BuildContext context) => const _FirstAdminDialog(),
    );
    if (draft == null || !mounted) return;

    try {
      await ref.read(appDatabaseProvider).usersDao.createUser(
            username: draft.username,
            fullName: draft.fullName,
            role: UserRole.admin,
            pin: draft.pin,
          );
      ref.invalidate(usersProvider);
      if (mounted) AppSnack.success(context, 'Administrador creado. Ya puede ingresar.');
    } on Object catch (error) {
      if (mounted) AppSnack.error(context, 'No se pudo crear el usuario: $error');
    }
  }

  void _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    final LogicalKeyboardKey key = event.logicalKey;

    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      _submit();
      return;
    }
    if (key == LogicalKeyboardKey.backspace) {
      _backspace();
      return;
    }
    final String? character = event.character;
    if (character == null || character.length != 1) return;
    final int code = character.codeUnitAt(0);
    if (code >= 0x30 && code <= 0x39) {
      _appendDigit(character);
    }
  }

  void _appendDigit(String digit) {
    if (_selected == null || _pin.length >= _maxPinLength) return;
    setState(() => _pin += digit);
  }

  void _backspace() {
    if (_pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  Future<void> _submit() async {
    if (_selected == null) return;
    final String pin = _pin;
    if (pin.length < PinHasher.minLength) {
      setState(() => _pin = '');
      return;
    }
    final bool ok = await ref.read(sessionProvider.notifier).login(pin);
    if (!mounted) return;
    if (!ok) {
      setState(() => _pin = '');
    }
  }
}

/// Iniciales para el avatar del usuario (máximo dos letras).
String _initials(String fullName) {
  final List<String> parts = fullName
      .trim()
      .split(RegExp(r'\s+'))
      .where((String part) => part.isNotEmpty)
      .toList(growable: false);
  if (parts.isEmpty) return '?';
  if (parts.length == 1) {
    final String single = parts.first;
    return (single.length >= 2 ? single.substring(0, 2) : single).toUpperCase();
  }
  return '${parts.first[0]}${parts[1][0]}'.toUpperCase();
}

/// Indicador de dígitos escritos.
class _PinDisplay extends StatelessWidget {
  const _PinDisplay({
    required this.length,
    required this.maxLength,
    this.error,
  });

  final int length;
  final int maxLength;
  final String? error;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            height: 64,
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: AppRadius.lgAll,
              border: Border.all(
                color: error == null ? AppColors.border : AppColors.red,
                width: error == null ? 1 : 1.4,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                for (int i = 0; i < length; i++)
                  Container(
                    width: 14,
                    height: 14,
                    margin: const EdgeInsets.symmetric(horizontal: 6),
                    decoration: const BoxDecoration(
                      color: AppColors.deepBlue,
                      shape: BoxShape.circle,
                    ),
                  ),
                if (length == 0)
                  Text(
                    'Escriba su PIN',
                    style: AppTypography.caption.copyWith(color: AppColors.textHint),
                  ),
              ],
            ),
          ),
          if (error != null) ...<Widget>[
            const SizedBox(height: AppSpacing.xs),
            InlineBanner(
              message: error!,
              icon: Icons.error_outline,
              color: AppColors.red,
            ),
          ],
        ],
      );
}

/// Teclado numérico en pantalla.
class _NumericKeypad extends StatelessWidget {
  const _NumericKeypad({
    required this.onDigit,
    required this.onBackspace,
    required this.onEnter,
    required this.onSubmitLabel,
  });

  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;
  final VoidCallback onEnter;
  final String onSubmitLabel;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        for (final List<String> row in const <List<String>>[
          <String>['1', '2', '3'],
          <String>['4', '5', '6'],
          <String>['7', '8', '9'],
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.xs),
            child: Row(
              children: <Widget>[
                for (final String digit in row)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: _KeypadButton(
                        label: digit,
                        onTap: () => onDigit(digit),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        Row(
          children: <Widget>[
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: _KeypadButton(
                  icon: Icons.backspace_outlined,
                  onTap: onBackspace,
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: _KeypadButton(
                  label: '0',
                  onTap: () => onDigit('0'),
                ),
              ),
            ),
            const Expanded(child: SizedBox.shrink()),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        PrimaryButton(
          label: onSubmitLabel,
          icon: Icons.login,
          large: true,
          expand: true,
          onPressed: onEnter,
        ),
      ],
    );
  }
}

class _KeypadButton extends StatefulWidget {
  const _KeypadButton({this.label, this.icon, required this.onTap});

  final String? label;
  final IconData? icon;
  final VoidCallback onTap;

  @override
  State<_KeypadButton> createState() => _KeypadButtonState();
}

class _KeypadButtonState extends State<_KeypadButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: AppDurations.instant,
          height: 52,
          decoration: BoxDecoration(
            color: _pressed ? AppColors.cyanSurface : AppColors.card,
            borderRadius: AppRadius.lgAll,
            border: Border.all(
              color: _pressed ? AppColors.cyan : AppColors.border,
            ),
          ),
          child: Center(
            child: widget.icon != null
                ? Icon(widget.icon, size: 20, color: AppColors.deepBlue)
                : Text(
                    widget.label!,
                    style: AppTypography.display.copyWith(fontSize: 22),
                  ),
          ),
        ),
      );
}

/// Tarjeta de usuario en la lista de acceso.
class _UserTile extends StatefulWidget {
  const _UserTile({required this.user, required this.onTap});

  final User user;
  final VoidCallback onTap;

  @override
  State<_UserTile> createState() => _UserTileState();
}

class _UserTileState extends State<_UserTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final User user = widget.user;
    final Color roleColor = switch (user.role) {
      UserRole.admin => AppColors.deepBlue,
      UserRole.supervisor => AppColors.cyan,
      UserRole.cashier => AppColors.success,
    };

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: AppDurations.fast,
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: _hovered ? AppColors.cyanSurface : AppColors.card,
            borderRadius: AppRadius.lgAll,
            border: Border.all(
              color: _hovered ? AppColors.cyan : AppColors.border,
            ),
            boxShadow: _hovered ? AppColors.cardShadow : null,
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: roleColor.withValues(alpha: 0.12),
                  borderRadius: AppRadius.mdAll,
                ),
                child: Center(
                  child: Text(
                    _initials(user.fullName),
                    style: AppTypography.bodyStrong.copyWith(
                      color: roleColor,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(user.fullName, style: AppTypography.bodyStrong),
                    Text(
                      <String>[
                        user.role.label,
                        if (user.employeeCode != null) '#${user.employeeCode}',
                        if (user.lastLoginAt != null)
                          'último acceso ${AppFormat.shortDate(user.lastLoginAt!)}',
                      ].join(' · '),
                      style: AppTypography.caption,
                    ),
                  ],
                ),
              ),
              const Icon(Icons.arrow_forward_ios, size: 14, color: AppColors.grey400),
            ],
          ),
        ),
      ),
    );
  }
}

/// Borrador del primer administrador.
@immutable
class _AdminDraft {
  const _AdminDraft({
    required this.username,
    required this.fullName,
    required this.pin,
  });

  final String username;
  final String fullName;
  final String pin;
}

/// Diálogo de creación del primer administrador.
class _FirstAdminDialog extends StatefulWidget {
  const _FirstAdminDialog();

  @override
  State<_FirstAdminDialog> createState() => _FirstAdminDialogState();
}

class _FirstAdminDialogState extends State<_FirstAdminDialog> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _username = TextEditingController();
  final TextEditingController _pin = TextEditingController();
  final TextEditingController _pinRepeat = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _username.dispose();
    _pin.dispose();
    _pinRepeat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        icon: const Icon(Icons.admin_panel_settings_outlined, color: AppColors.deepBlue),
        title: const Text('Primer administrador'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                controller: _name,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Nombre completo'),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: _username,
                decoration: const InputDecoration(
                  labelText: 'Usuario (para reportes y auditoría)',
                  hintText: 'gerente',
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: _pin,
                      obscureText: true,
                      keyboardType: TextInputType.number,
                      maxLength: 8,
                      inputFormatters: <TextInputFormatter>[
                        FilteringTextInputFormatter.digitsOnly,
                      ],
                      decoration: const InputDecoration(
                        labelText: 'PIN',
                        counterText: '',
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: TextField(
                      controller: _pinRepeat,
                      obscureText: true,
                      keyboardType: TextInputType.number,
                      maxLength: 8,
                      inputFormatters: <TextInputFormatter>[
                        FilteringTextInputFormatter.digitsOnly,
                      ],
                      decoration: const InputDecoration(
                        labelText: 'Repita el PIN',
                        counterText: '',
                      ),
                    ),
                  ),
                ],
              ),
              if (_error != null) ...<Widget>[
                const SizedBox(height: AppSpacing.sm),
                InlineBanner(
                  message: _error!,
                  icon: Icons.error_outline,
                  color: AppColors.red,
                ),
              ],
              const SizedBox(height: AppSpacing.sm),
              const HintText(
                'El PIN debe tener entre 4 y 8 dígitos. Se guarda cifrado con PBKDF2 '
                'y sal aleatoria: nadie puede leerlo desde la base de datos.',
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: _submit,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.orange,
              foregroundColor: AppColors.white,
            ),
            child: const Text('Crear y continuar'),
          ),
        ],
      );

  void _submit() {
    final String name = _name.text.trim();
    final String username = _username.text.trim().toLowerCase();
    final String pin = _pin.text.trim();

    String? error;
    if (name.isEmpty) {
      error = 'Escriba el nombre completo.';
    } else if (username.length < 2) {
      error = 'El nombre de usuario debe tener al menos 2 caracteres.';
    } else if (_pin.text != _pinRepeat.text) {
      error = 'Los PIN no coinciden.';
    } else {
      error = PinHasher.validate(pin);
    }

    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.of(context).pop(
      _AdminDraft(username: username, fullName: name, pin: pin),
    );
  }
}
