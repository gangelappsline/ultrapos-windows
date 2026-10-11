import 'dart:async';
import 'dart:io';
// Solo `PlatformDispatcher`: evita ambigüedades con los reexports de Flutter.
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
// `show Bootstrap` es intencional: bootstrap.dart también expone un
// `unawaited`, que chocaría con el de `dart:async`.
import 'app/bootstrap.dart' show Bootstrap;
import 'core/config/app_config.dart';
import 'core/logging/app_logger.dart';
import 'core/theme/app_colors.dart';
import 'core/theme/app_spacing.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/app_typography.dart';

/// Punto de entrada de UltraPOS en Windows.
///
/// Este archivo es deliberadamente corto: **aquí no vive lógica de negocio**.
/// Todo el arranque real (logger, ventana nativa, secretos, base de datos,
/// configuración del equipo, hardware y sincronización) está en
/// [Bootstrap.run], que devuelve el contenedor de Riverpod listo para usarse.
///
/// Responsabilidades de `main.dart`, en orden:
///   1. Capturar **cualquier** error (de Flutter, asíncrono o de zona) en el
///      log de diagnóstico antes de que la aplicación muera en silencio.
///   2. Arrancar el contenedor de dependencias.
///   3. Montar [UltraPosApp] dentro de [UncontrolledProviderScope].
///   4. Si el arranque falla, mostrar en pantalla **qué** falló y **dónde**
///      quedó registrado. En una caja, un "no abre" sin explicación es un
///      ticket de soporte; con la causa y el log, es una solución.
void main() {
  runZonedGuarded<void>(
    () {
      // Errores del framework Flutter (build, layout, pintado).
      FlutterError.onError = (FlutterErrorDetails details) {
        FlutterError.presentError(details);
        Log.instance.captureFlutterError(details);
      };

      // Errores asíncronos no capturados (futuros sin await, temporizadores,
      // streams). Devolver true evita que el error tumbe la aplicación: en un
      // POS una venta en curso vale más que un fallo puntual.
      PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
        Log.instance.captureUncaught(error, stack);
        return true;
      };

      unawaited(_start());
    },
    // Errores que escapan incluso a lo anterior: última red de seguridad.
    (Object error, StackTrace stack) => Log.instance.captureUncaught(error, stack),
  );
}

/// Arranca el contenedor de dependencias y monta la interfaz.
Future<void> _start() async {
  try {
    final ProviderContainer container = await Bootstrap.run();
    runApp(
      UncontrolledProviderScope(
        container: container,
        child: const UltraPosApp(),
      ),
    );
  } on Object catch (error, stackTrace) {
    // Sin base de datos no hay POS: se muestra la causa en pantalla en lugar
    // de dejar la ventana en blanco (el cajero no puede leer la consola).
    Log.instance.critical(
      'main',
      'No se pudo iniciar UltraPOS',
      error: error,
      stackTrace: stackTrace,
    );
    runApp(_StartupFailureApp(error: error, stackTrace: stackTrace));
  }
}

/// Pantalla de último recurso cuando el arranque falla.
///
/// No depende de Riverpod, ni de la base de datos, ni del tema completo: solo
/// de Flutter. Su único trabajo es decir qué falló y dónde quedó registrado,
/// para que soporte pueda actuar sin acceso a la máquina del cliente.
class _StartupFailureApp extends StatelessWidget {
  const _StartupFailureApp({required this.error, required this.stackTrace});

  final Object error;
  final StackTrace stackTrace;

  @override
  Widget build(BuildContext context) {
    final String? logPath = Log.instance.logFilePath;
    final String detail = 'UltraPOS ${AppConfig.appVersion}\n'
        'Error: $error\n\n'
        '$stackTrace';

    return MaterialApp(
      title: AppConfig.windowTitle,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      home: Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.xxl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Row(
                    children: <Widget>[
                      Icon(Icons.error_outline, size: 36, color: AppColors.red),
                      SizedBox(width: AppSpacing.md),
                      Text(
                        'UltraPOS no pudo iniciar',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w600,
                          color: AppColors.deepBlue,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  const Text(
                    'El equipo no pudo preparar los datos locales (base de datos o '
                    'secretos del dispositivo). La aplicación no puede operar sin '
                    'ellos, así que no se abrió ninguna venta.',
                    style: TextStyle(fontSize: 14, color: AppColors.deepBlue),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(AppSpacing.md),
                    decoration: BoxDecoration(
                      color: AppColors.white,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.redSurface, width: 1.5),
                    ),
                    child: SelectableText(
                      '$error',
                      style: AppTypography.monospace,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  SelectableText(
                    logPath == null
                        ? 'No se pudo abrir el archivo de log.'
                        : 'Registro de diagnóstico: $logPath',
                    style: AppTypography.caption,
                  ),
                  const SizedBox(height: AppSpacing.xxl),
                  Row(
                    children: <Widget>[
                      FilledButton.icon(
                        onPressed: () => _copyDetail(context, detail),
                        icon: const Icon(Icons.copy_all_outlined, size: 18),
                        label: const Text('Copiar detalle'),
                      ),
                      const SizedBox(width: AppSpacing.md),
                      OutlinedButton(
                        onPressed: () async {
                          // Se cierra el log antes de salir para no perder el
                          // último registro (justo el que importa).
                          await Log.instance.dispose();
                          exit(1);
                        },
                        child: const Text('Salir'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _copyDetail(BuildContext context, String detail) {
    unawaited(Clipboard.setData(ClipboardData(text: detail)));
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('Detalle copiado al portapapeles.')),
    );
  }
}
