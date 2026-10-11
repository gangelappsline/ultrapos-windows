import 'dart:io';
import 'dart:typed_data';

import '../logging/app_logger.dart';
import 'printer_config.dart';
import 'win_com.dart';
import 'win_spool.dart';

/// Resultado de un envío a la impresora.
class PrintOutcome {
  const PrintOutcome({
    required this.success,
    this.bytesSent = 0,
    this.errorMessage,
    this.transport = '',
    this.durationMs = 0,
  });

  final bool success;
  final int bytesSent;
  final String? errorMessage;
  final String transport;

  /// Tiempo total del envío (útil para detectar impresoras lentas o en riesgo).
  final int durationMs;

  static PrintOutcome ok(int bytes, String transport, {int durationMs = 0}) =>
      PrintOutcome(
        success: true,
        bytesSent: bytes,
        transport: transport,
        durationMs: durationMs,
      );

  static PrintOutcome failure(String message, String transport, {int durationMs = 0}) =>
      PrintOutcome(
        success: false,
        errorMessage: message,
        transport: transport,
        durationMs: durationMs,
      );
}

/// Comando ESC/POS de apertura del cajón de dinero (pin 2).
///
/// `ESC p 0 25 250`: el estándar que implementan todas las impresoras térmicas
/// con conector RJ11 para cajón. Es idempotente respecto al ticket: se puede
/// enviar solo, sin imprimir nada.
const List<int> kOpenDrawerCommand = <int>[0x1B, 0x70, 0x00, 0x19, 0xFA];

/// Impresoras instaladas en Windows (lista vacía fuera de Windows).
List<String> availableWindowsPrinters() => WinSpool.listPrinters();

/// Impresora predeterminada de Windows.
String? defaultWindowsPrinter() => WinSpool.defaultPrinter();

/// Puertos COM detectados en el equipo.
List<String> availableComPorts() => WinCom.availablePorts();

/// Transmisión de bytes ESC/POS al dispositivo.
///
/// Es una abstracción deliberada: el **generador** de bytes es el mismo para
/// todas las impresoras, lo único que cambia es el camino hasta el cabezal
/// (spooler de Windows, socket de red, puerto serie o PDF).
abstract interface class PrinterTransport {
  /// Nombre legible del transporte (para el diagnóstico).
  String get description;

  /// Envía los bytes. Devuelve el resultado; no lanza por fallos del
  /// dispositivo (la capa superior decide si avisar o usar el respaldo PDF).
  Future<PrintOutcome> send(List<int> bytes);

  /// ¿El destino parece accesible? Se usa en el diagnóstico de hardware.
  Future<bool> probe();
}

/// Impresión por el spooler de Windows en modo RAW.
class WindowsSpoolTransport implements PrinterTransport {
  WindowsSpoolTransport(this.printerName);

  /// `null` = impresora predeterminada del sistema.
  final String? printerName;

  @override
  String get description => 'Windows spooler · ${printerName ?? 'predeterminada'}';

  @override
  Future<PrintOutcome> send(List<int> bytes) async {
    try {
      WinSpool.sendRaw(bytes, printerName: printerName);
      return PrintOutcome.ok(bytes.length, description);
    } on WinSpoolException catch (error) {
      return PrintOutcome.failure(error.message, description);
    } on Object catch (error) {
      return PrintOutcome.failure('Error al imprimir: $error', description);
    }
  }

  @override
  Future<bool> probe() async {
    if (!WinSpool.isSupported) return false;
    if (printerName == null || printerName!.isEmpty) {
      return WinSpool.defaultPrinter() != null;
    }
    return WinSpool.listPrinters().contains(printerName);
  }
}

/// Impresora de red ESC/POS: socket TCP al puerto 9100 (el estándar de facto).
///
/// Es el transporte más rápido y el más común en restaurantes con varias
/// cajas y una impresora por área (barra, cocina).
class NetworkPrinterTransport implements PrinterTransport {
  NetworkPrinterTransport({
    required this.host,
    this.port = 9100,
    this.timeout = const Duration(seconds: 5),
  });

  final String host;
  final int port;
  final Duration timeout;

  @override
  String get description => 'Red · $host:$port';

  @override
  Future<PrintOutcome> send(List<int> bytes) async {
    Socket? socket;
    try {
      socket = await Socket.connect(host, port, timeout: timeout);
      socket.add(bytes);
      await socket.flush();
      return PrintOutcome.ok(bytes.length, description);
    } on SocketException catch (error) {
      return PrintOutcome.failure(
        'No se pudo conectar con la impresora $host:$port (${error.osError?.message ?? error.message}). '
        'Verifique que esté encendida, en la misma red y con la IP correcta.',
        description,
      );
    } on Object catch (error) {
      return PrintOutcome.failure('Error de red al imprimir: $error', description);
    } finally {
      try {
        await socket?.close();
        socket?.destroy();
      } on Object {
        // El cierre de un socket ya cerrado no debe romper el flujo de venta.
      }
    }
  }

  @override
  Future<bool> probe() async {
    Socket? socket;
    try {
      socket = await Socket.connect(host, port, timeout: timeout);
      return true;
    } on Object {
      return false;
    } finally {
      socket?.destroy();
    }
  }
}

/// Impresora/cajón conectado a un puerto serie.
class SerialPrinterTransport implements PrinterTransport {
  SerialPrinterTransport({required this.port, this.baudRate = 9600});

  final String port;
  final int baudRate;

  @override
  String get description => 'Serie · $port @ $baudRate';

  @override
  Future<PrintOutcome> send(List<int> bytes) async {
    try {
      WinCom.write(bytes, port: port, baudRate: baudRate);
      return PrintOutcome.ok(bytes.length, description);
    } on WinComException catch (error) {
      return PrintOutcome.failure(error.message, description);
    } on Object catch (error) {
      return PrintOutcome.failure('Error al escribir en $port: $error', description);
    }
  }

  @override
  Future<bool> probe() async =>
      WinCom.isSupported && WinCom.availablePorts().contains(port.toUpperCase());
}

/// Envía los bytes y reintenta una vez ante un fallo transitorio.
///
/// Un POS recibe pedidos con prisa: si la impresora estaba ocupada con el
/// ticket anterior, un único reintento con una pausa corta resuelve la mayoría
/// de los fallos reales sin aburrir al cajero con un diálogo de error.
Future<PrintOutcome> sendWithRetry(
  PrinterTransport transport,
  List<int> bytes, {
  int attempts = 2,
  Duration delay = const Duration(milliseconds: 350),
}) async {
  final Stopwatch watch = Stopwatch()..start();
  PrintOutcome outcome = await transport.send(bytes);
  int remaining = attempts - 1;
  while (!outcome.success && remaining > 0) {
    await Future<void>.delayed(delay);
    Log.warning('printer', 'Reintentando impresión (${outcome.transport})');
    outcome = await transport.send(bytes);
    remaining--;
  }
  watch.stop();
  // El tiempo acumulado incluye los reintentos y las esperas.
  return PrintOutcome(
    success: outcome.success,
    bytesSent: outcome.bytesSent,
    errorMessage: outcome.errorMessage,
    transport: outcome.transport,
    durationMs: watch.elapsedMilliseconds,
  );
}

/// Crea el transporte adecuado según la configuración, o `null` si no hay.
PrinterTransport? createTransport(PrinterConfig config) {
  switch (config.type) {
    case PrinterType.windowsSpool:
      final String? name = config.windowsPrinterName;
      return WindowsSpoolTransport(name == null || name.isEmpty ? null : name);
    case PrinterType.network:
      final String? host = config.networkHost;
      if (host == null || host.isEmpty) return null;
      return NetworkPrinterTransport(host: host, port: config.networkPort);
    case PrinterType.serial:
      final String? port = config.comPort;
      if (port == null || port.isEmpty) return null;
      return SerialPrinterTransport(port: port, baudRate: config.comBaudRate);
    case PrinterType.pdf:
    case PrinterType.none:
      return null;
  }
}

/// Genera los bytes de la prueba de impresora con la configuración indicada.
Future<PrintOutcome> testPrinter(PrinterConfig config, List<int> bytes) {
  final PrinterTransport? transport = createTransport(config);
  if (transport == null) {
    return Future<PrintOutcome>.value(
      PrintOutcome.failure(
        'No hay impresora configurada (el modo actual genera el ticket en PDF).',
        'sin transporte',
      ),
    );
  }
  return sendWithRetry(transport, bytes);
}

/// Indica si el sistema ve esta impresora ahora mismo (diagnóstico).
Future<bool> transportIsAvailable(PrinterConfig config) async {
  final PrinterTransport? transport = createTransport(config);
  if (transport == null) return false;
  return transport.probe();
}

/// Utilidad: convierte una lista de enteros a bytes sin copias innecesarias.
Uint8List toBytes(List<int> data) =>
    data is Uint8List ? data : Uint8List.fromList(data);
