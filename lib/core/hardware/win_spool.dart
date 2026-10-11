import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../logging/app_logger.dart';

/// Impresión RAW en Windows a través del **spooler** (`winspool.drv`).
///
/// Motivo de diseño: los comandos ESC/POS deben llegar al cabezal **sin
/// interpretación**. Si se envía por el driver en modo texto, el driver añade
/// saltos de página, márgenes y fuentes, y el ticket sale deformado o cortado.
/// La vía correcta es `StartDocPrinterW` con `pDatatype = "RAW"`, que entrega
/// los bytes tal cual (misma ruta que usa el driver de la impresora).
///
/// Todo el archivo es no-op fuera de Windows: el POS debe poder compilarse y
/// ejecutar sus pruebas en otros sistemas.
class WinSpool {
  WinSpool._();

  static const String _scope = 'winspool';

  static DynamicLibrary? _library;
  static bool _unavailable = false;

  static DynamicLibrary? get _lib {
    if (_unavailable) return null;
    if (_library != null) return _library;
    try {
      _library = DynamicLibrary.open('winspool.drv');
      return _library;
    } on Object catch (error) {
      _unavailable = true;
      Log.warning(_scope, 'winspool.drv no disponible: $error');
      return null;
    }
  }

  /// ¿Se puede imprimir en esta máquina?
  static bool get isSupported => _lib != null;

  // ---------------------------------------------------------------------------
  // Impresión RAW
  // ---------------------------------------------------------------------------

  /// Envía [bytes] a la impresora [printerName] (o a la predeterminada si es
  /// `null`) en modo RAW.
  ///
  /// Lanza [WinSpoolException] con el motivo concreto si Windows rechaza la
  /// operación, para que la interfaz pueda decir *qué* falló (impresora
  /// apagada, nombre incorrecto, spooler detenido…).
  static void sendRaw(List<int> bytes, {String? printerName}) {
    final DynamicLibrary? library = _lib;
    if (library == null) {
      throw const WinSpoolException(
        'La impresión RAW solo está disponible en Windows.',
        code: 0,
      );
    }
    if (bytes.isEmpty) return;

    // --- Resolución de la impresora destino ---
    final String? target = printerName ?? defaultPrinter();
    if (target == null || target.trim().isEmpty) {
      throw const WinSpoolException(
        'No se encontró ninguna impresora predeterminada. '
        'Configure la impresora en Configuración > Impresora.',
        code: 0,
      );
    }

    final _WinSpoolBindings api = _WinSpoolBindings(library);
    final Pointer<Utf16> namePtr = target.toNativeUtf16();
    final Pointer<Pointer<Void>> handlePtr = calloc<Pointer<Void>>();

    try {
      final int opened = api.openPrinter(namePtr, handlePtr, nullptr);
      if (opened == 0) {
        throw WinSpoolException(
          'Windows no pudo abrir la impresora "$target" (error ${api.lastError()}).',
          code: api.lastError(),
        );
      }

      final Pointer<Void> handle = handlePtr.value;
      try {
        final Pointer<_DocInfo1> docInfo = calloc<_DocInfo1>();
        final Pointer<Utf16> docName = 'UltraPOS Ticket'.toNativeUtf16();
        final Pointer<Utf16> dataType = 'RAW'.toNativeUtf16();
        try {
          docInfo.ref
            ..pDocName = docName
            ..pOutputFile = nullptr
            ..pDatatype = dataType;

          final int job = api.startDocPrinter(handle, 1, docInfo);
          if (job == 0) {
            throw WinSpoolException(
              'El spooler rechazó el documento (error ${api.lastError()}). '
              '¿Está detenido el servicio de cola de impresión?',
              code: api.lastError(),
            );
          }

          api.startPagePrinter(handle);

          final Pointer<Uint8> buffer = calloc<Uint8>(bytes.length);
          final Pointer<Uint32> writtenPtr = calloc<Uint32>();
          try {
            buffer.asTypedList(bytes.length).setAll(0, Uint8List.fromList(bytes));
            final int ok = api.writePrinter(
              handle,
              buffer.cast<Void>(),
              bytes.length,
              writtenPtr,
            );
            if (ok == 0) {
              throw WinSpoolException(
                'La impresora "$target" no aceptó los datos '
                '(error ${api.lastError()}). Verifique que esté encendida y con papel.',
                code: api.lastError(),
              );
            }
            final int written = writtenPtr.value;
            if (written != bytes.length) {
              Log.warning(
                _scope,
                'Escritura parcial: $written de ${bytes.length} bytes',
              );
            }
          } finally {
            calloc.free(buffer);
            calloc.free(writtenPtr);
          }

          api.endPagePrinter(handle);
          api.endDocPrinter(handle);
          Log.info(
            _scope,
            'Ticket enviado a "$target"',
            data: <String, Object?>{'bytes': bytes.length, 'job': job},
          );
        } finally {
          calloc.free(docInfo);
          calloc.free(docName);
          calloc.free(dataType);
        }
      } finally {
        api.closePrinter(handle);
      }
    } finally {
      calloc.free(namePtr);
      calloc.free(handlePtr);
    }
  }

  // ---------------------------------------------------------------------------
  // Impresoras instaladas
  // ---------------------------------------------------------------------------

  /// Lista las impresoras locales y de red conocidas por Windows.
  ///
  /// Se usa `EnumPrintersW` nivel 4 (`PRINTER_INFO_4`), que es la estructura
  /// más ligera y suficiente para un selector de impresora.
  static List<String> listPrinters() {
    final DynamicLibrary? library = _lib;
    if (library == null) return const <String>[];

    final _WinSpoolBindings api = _WinSpoolBindings(library);
    // PRINTER_ENUM_LOCAL (0x2) | PRINTER_ENUM_CONNECTIONS (0x4)
    const int flags = 0x2 | 0x4;

    final Pointer<Uint32> neededPtr = calloc<Uint32>();
    final Pointer<Uint32> returnedPtr = calloc<Uint32>();

    try {
      // Primera llamada: solo para conocer el tamaño necesario.
      api.enumPrinters(flags, nullptr, 4, nullptr, 0, neededPtr, returnedPtr);
      final int needed = neededPtr.value;
      if (needed <= 0) return const <String>[];

      final Pointer<Uint8> buffer = calloc<Uint8>(needed + 1024);
      try {
        final int ok = api.enumPrinters(
          flags,
          nullptr,
          4,
          buffer.cast<Void>(),
          needed + 1024,
          neededPtr,
          returnedPtr,
        );
        if (ok == 0) return const <String>[];

        final int count = returnedPtr.value;
        final List<String> printers = <String>[];
        for (int i = 0; i < count; i++) {
          final Pointer<_PrinterInfo4> info =
              Pointer<_PrinterInfo4>.fromAddress(buffer.address + i * sizeOf<_PrinterInfo4>());
          final String name = info.ref.pPrinterName.toDartString();
          if (name.isNotEmpty) printers.add(name);
        }
        printers.sort();
        return List<String>.unmodifiable(printers);
      } finally {
        calloc.free(buffer);
      }
    } finally {
      calloc.free(neededPtr);
      calloc.free(returnedPtr);
    }
  }

  /// Nombre de la impresora predeterminada de Windows.
  static String? defaultPrinter() {
    final DynamicLibrary? library = _lib;
    if (library == null) return null;

    final _WinSpoolBindings api = _WinSpoolBindings(library);
    final Pointer<Uint32> sizePtr = calloc<Uint32>();
    try {
      // Primera llamada con buffer nulo: devuelve el tamaño necesario.
      api.getDefaultPrinter(nullptr, sizePtr);
      final int size = sizePtr.value;
      if (size <= 1) return null;

      final Pointer<Utf16> buffer = calloc<Utf16>(size);
      try {
        final int ok = api.getDefaultPrinter(buffer, sizePtr);
        if (ok == 0) return null;
        final String name = buffer.toDartString();
        return name.isEmpty ? null : name;
      } finally {
        calloc.free(buffer);
      }
    } finally {
      calloc.free(sizePtr);
    }
  }
}

/// Error de impresión en Windows con el código nativo adjunto.
class WinSpoolException implements Exception {
  const WinSpoolException(this.message, {required this.code});

  final String message;

  /// Código de error de Windows (`GetLastError`).
  final int code;

  @override
  String toString() => code == 0 ? message : '$message (código $code)';
}

// -----------------------------------------------------------------------------
// Estructuras nativas
// -----------------------------------------------------------------------------

/// `DOC_INFO_1W` (winspool).
final class _DocInfo1 extends Struct {
  external Pointer<Utf16> pDocName;
  external Pointer<Utf16> pOutputFile;
  external Pointer<Utf16> pDatatype;
}

/// `PRINTER_INFO_4W` (winspool): información mínima de una impresora.
final class _PrinterInfo4 extends Struct {
  external Pointer<Utf16> pPrinterName;
  external Pointer<Utf16> pServerName;

  @Uint32()
  external int attributes;
}

/// Enlaces a `winspool.drv` y `kernel32.dll`.
class _WinSpoolBindings {
  _WinSpoolBindings(DynamicLibrary spool)
      : _openPrinter = spool.lookupFunction<
            Int32 Function(Pointer<Utf16>, Pointer<Pointer<Void>>, Pointer<Void>),
            int Function(Pointer<Utf16>, Pointer<Pointer<Void>>, Pointer<Void>)>(
          'OpenPrinterW',
        ),
        _closePrinter = spool.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>(
          'ClosePrinter',
        ),
        _startDocPrinter = spool.lookupFunction<
            Int32 Function(Pointer<Void>, Uint32, Pointer<_DocInfo1>),
            int Function(Pointer<Void>, int, Pointer<_DocInfo1>)>(
          'StartDocPrinterW',
        ),
        _endDocPrinter = spool.lookupFunction<
            Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)>('EndDocPrinter'),
        _startPagePrinter = spool.lookupFunction<
            Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)>('StartPagePrinter'),
        _endPagePrinter = spool.lookupFunction<
            Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)>('EndPagePrinter'),
        _writePrinter = spool.lookupFunction<
            Int32 Function(Pointer<Void>, Pointer<Void>, Uint32, Pointer<Uint32>),
            int Function(Pointer<Void>, Pointer<Void>, int, Pointer<Uint32>)>(
          'WritePrinter',
        ),
        _enumPrinters = spool.lookupFunction<
            Int32 Function(
              Uint32,
              Pointer<Utf16>,
              Uint32,
              Pointer<Void>,
              Uint32,
              Pointer<Uint32>,
              Pointer<Uint32>,
            ),
            int Function(
              int,
              Pointer<Utf16>,
              int,
              Pointer<Void>,
              int,
              Pointer<Uint32>,
              Pointer<Uint32>,
            )>('EnumPrintersW'),
        _getDefaultPrinter =
            spool.lookupFunction<Int32 Function(Pointer<Utf16>, Pointer<Uint32>),
                int Function(Pointer<Utf16>, Pointer<Uint32>)>('GetDefaultPrinterW'),
        _getLastError = DynamicLibrary.open('kernel32.dll').lookupFunction<
            Uint32 Function(),
            int Function()>('GetLastError');

  final int Function(Pointer<Utf16>, Pointer<Pointer<Void>>, Pointer<Void>) _openPrinter;
  final int Function(Pointer<Void>) _closePrinter;
  final int Function(Pointer<Void>, int, Pointer<_DocInfo1>) _startDocPrinter;
  final int Function(Pointer<Void>) _endDocPrinter;
  final int Function(Pointer<Void>) _startPagePrinter;
  final int Function(Pointer<Void>) _endPagePrinter;
  final int Function(Pointer<Void>, Pointer<Void>, int, Pointer<Uint32>) _writePrinter;
  final int Function(
    int,
    Pointer<Utf16>,
    int,
    Pointer<Void>,
    int,
    Pointer<Uint32>,
    Pointer<Uint32>,
  ) _enumPrinters;
  final int Function(Pointer<Utf16>, Pointer<Uint32>) _getDefaultPrinter;
  final int Function() _getLastError;

  int openPrinter(Pointer<Utf16> name, Pointer<Pointer<Void>> handle, Pointer<Void> defaults) =>
      _openPrinter(name, handle, defaults);

  int closePrinter(Pointer<Void> handle) => _closePrinter(handle);

  int startDocPrinter(Pointer<Void> handle, int level, Pointer<_DocInfo1> info) =>
      _startDocPrinter(handle, level, info);

  int endDocPrinter(Pointer<Void> handle) => _endDocPrinter(handle);

  int startPagePrinter(Pointer<Void> handle) => _startPagePrinter(handle);

  int endPagePrinter(Pointer<Void> handle) => _endPagePrinter(handle);

  int writePrinter(
    Pointer<Void> handle,
    Pointer<Void> buffer,
    int length,
    Pointer<Uint32> written,
  ) =>
      _writePrinter(handle, buffer, length, written);

  int enumPrinters(
    int flags,
    Pointer<Utf16> name,
    int level,
    Pointer<Void> buffer,
    int bufferSize,
    Pointer<Uint32> needed,
    Pointer<Uint32> returned,
  ) =>
      _enumPrinters(flags, name, level, buffer, bufferSize, needed, returned);

  int getDefaultPrinter(Pointer<Utf16> buffer, Pointer<Uint32> size) =>
      _getDefaultPrinter(buffer, size);

  int lastError() => _getLastError();
}
