import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../logging/app_logger.dart';

/// Escritura directa a un puerto serie (COM) de Windows vía `kernel32.dll`.
///
/// Casos de uso reales en un POS:
///  * impresora matricial/térmica conectada por USB-serie (adaptador
///    CH340/FTDI) que no expone driver de impresora;
///  * **cajón de dinero conectado directamente al puerto COM** (sin impresora).
///
/// Se abre y se cierra el puerto en cada envío a propósito: mantener el handle
/// abierto bloquea el puerto para otros programas (el utilitario del
/// proveedor, una herramienta de diagnóstico) y complica el soporte técnico.
/// El coste (~10 ms) es irrelevante frente a la apertura del cajón.
class WinCom {
  WinCom._();

  static const String _scope = 'wincom';

  static DynamicLibrary? _library;
  static bool _unavailable = false;

  // Constantes de `CreateFileW`.
  static const int _genericRead = 0x80000000;
  static const int _genericWrite = 0x40000000;
  static const int _openExisting = 3;

  // Constantes de `PurgeComm`.
  static const int _purgeTxAbort = 0x0001;
  static const int _purgeRxAbort = 0x0002;
  static const int _purgeTxClear = 0x0004;
  static const int _purgeRxClear = 0x0008;

  static DynamicLibrary? get _lib {
    if (_unavailable) return null;
    if (_library != null) return _library;
    try {
      _library = DynamicLibrary.open('kernel32.dll');
      return _library;
    } on Object catch (error) {
      _unavailable = true;
      Log.warning(_scope, 'kernel32.dll no disponible: $error');
      return null;
    }
  }

  static bool get isSupported => _lib != null;

  /// Envía [bytes] al puerto [port] (por ejemplo `COM3` o `\\.\COM10`).
  ///
  /// [baudRate] debe coincidir con el de la impresora/cajón (9600 por defecto).
  /// Lanza [WinComException] con el motivo concreto si falla.
  static void write(
    List<int> bytes, {
    required String port,
    int baudRate = 9600,
    bool purgeBeforeWrite = true,
  }) {
    final DynamicLibrary? library = _lib;
    if (library == null) {
      throw const WinComException(
        'El puerto serie solo está disponible en Windows.',
        errorCode: 0,
      );
    }
    if (bytes.isEmpty) return;

    final _Kernel32 api = _Kernel32(library);
    final Pointer<Utf16> path = _devicePath(port).toNativeUtf16();

    try {
      final int handle = api.createFile(
        path,
        _genericRead | _genericWrite,
        0, // sin compartición: evita que dos procesos mezclen comandos
        nullptr,
        _openExisting,
        0,
        nullptr,
      );

      if (handle == -1) {
        final int error = api.lastError();
        throw WinComException(
          'No se pudo abrir el puerto "$port" (error $error). '
          'Verifique que exista, que no esté en uso por otro programa '
          'y que el dispositivo esté conectado.',
          errorCode: error,
          port: port,
        );
      }

      try {
        api.setupComm(handle, 4096, 4096);

        if (purgeBeforeWrite) {
          // Limpia restos de comandos anteriores: si quedó a medias un corte de
          // papel o una apertura de cajón, el comando nuevo se corrompería.
          api.purgeComm(
            handle,
            _purgeTxAbort | _purgeRxAbort | _purgeTxClear | _purgeRxClear,
          );
        }

        final Pointer<_Dcb> dcb = calloc<_Dcb>();
        try {
          dcb.ref
            ..dcbLength = sizeOf<_Dcb>()
            ..baudRate = baudRate
            ..flags = _fBinary
            ..byteSize = 8
            ..parity = 0 // NOPARITY
            ..stopBits = 0 // ONESTOPBIT
            ..fDtrControl = 1 // DTR_CONTROL_ENABLE: muchas impresoras lo exigen
            ..fRtsControl = 1; // RTS_CONTROL_ENABLE

          if (api.setCommState(handle, dcb) == 0) {
            final int error = api.lastError();
            throw WinComException(
              'Windows rechazó la configuración del puerto "$port" a $baudRate bps '
              '(error $error).'
              'Pruebe con 9600, 19200 o 38400 baudios, según el equipo.',
              errorCode: error,
              port: port,
            );
          }
        } finally {
          calloc.free(dcb);
        }

        final Pointer<Uint8> buffer = calloc<Uint8>(bytes.length);
        final Pointer<Uint32> writtenPtr = calloc<Uint32>();
        try {
          buffer.asTypedList(bytes.length).setAll(0, Uint8List.fromList(bytes));
          final int ok = api.writeFile(
            handle,
            buffer.cast<Void>(),
            bytes.length,
            writtenPtr,
            nullptr,
          );
          if (ok == 0) {
            final int error = api.lastError();
            throw WinComException(
              'La escritura en "$port" falló (error $error). '
              'Revise el cable y la alimentación del dispositivo.',
              errorCode: error,
              port: port,
            );
          }
          api.flushFileBuffers(handle);
          Log.info(
            _scope,
            'Bytes enviados al puerto serie',
            data: <String, Object?>{
              'port': port,
              'bytes': writtenPtr.value,
              'baud': baudRate,
            },
          );
        } finally {
          calloc.free(buffer);
          calloc.free(writtenPtr);
        }
      } finally {
        api.closeHandle(handle);
      }
    } finally {
      calloc.free(path);
    }
  }

  /// Puertos COM presentes en el sistema, ordenados naturalmente (COM2 < COM10).
  ///
  /// Se sondean los 32 primeros puertos: `CreateFileW` es rápido y evita
  /// depender de la consulta WMI (que requiere permisos y es lenta).
  static List<String> availablePorts({int maxPort = 32}) {
    final DynamicLibrary? library = _lib;
    if (library == null) return const <String>[];

    final _Kernel32 api = _Kernel32(library);
    final List<String> ports = <String>[];

    for (int i = 1; i <= maxPort; i++) {
      final String port = 'COM$i';
      final Pointer<Utf16> path = _devicePath(port).toNativeUtf16();
      try {
        final int handle = api.createFile(
          path,
          _genericRead | _genericWrite,
          0,
          nullptr,
          _openExisting,
          0,
          nullptr,
        );
        if (handle != -1) {
          api.closeHandle(handle);
          ports.add(port);
        }
      } finally {
        calloc.free(path);
      }
    }
    return List<String>.unmodifiable(ports);
  }

  /// Nombre de dispositivo completo que exige `CreateFileW`.
  ///
  /// Windows no acepta `"COM3"` para puertos mayores que COM9: la forma
  /// canónica es `\\.\COM3`.
  static String _devicePath(String port) {
    final String clean = port.trim().toUpperCase().replaceAll(r'\\.\', '');
    if (clean.startsWith('COM')) return r'\\.\' + clean;
    return port;
  }
}

/// Error de comunicación serie con el código nativo adjunto.
class WinComException implements Exception {
  const WinComException(this.message, {required this.errorCode, this.port});

  final String message;
  final int errorCode;
  final String? port;

  @override
  String toString() => message;
}

// -----------------------------------------------------------------------------
// Estructuras nativas
// -----------------------------------------------------------------------------

/// `DCB` (Device Control Block) de la API de comunicaciones de Windows.
///
/// Se replica **campo a campo** y en orden: el layout debe coincidir
/// exactamente con el de Windows o `SetCommState` fallaría de forma silenciosa.
final class _Dcb extends Struct {
  @Uint32()
  external int dcbLength;

  @Uint32()
  external int baudRate;

  /// Bitfield `fBinary:1 fParity:1 fOutxCtsFlow:1 fOutxDsrFlow:1 ...`
  /// Se construye el valor completo de 32 bits (`0x00000001` = fBinary).
  @Uint32()
  external int flags;

  @Uint16()
  external int reserved;

  @Uint16()
  external int xonLim;

  @Uint16()
  external int xoffLim;

  @Uint8()
  external int byteSize;

  @Uint8()
  external int parity;

  @Uint8()
  external int stopBits;

  @Int16()
  external int xonChar;

  @Int16()
  external int xoffChar;

  @Int16()
  external int errorChar;

  @Int16()
  external int eofChar;

  @Int16()
  external int evtChar;

  @Uint16()
  external int reserved1;

  /// `fDtrControl` (subcampo del bitfield de control de flujo).
  set fDtrControl(int value) => flags |= (value & 0x3) << 4;

  /// `fRtsControl` (subcampo del bitfield de control de flujo).
  set fRtsControl(int value) => flags |= (value & 0x3) << 12;
}

/// Constante `fBinary` del campo de flags de `DCB`.
const int _fBinary = 0x00000001;

/// Enlaces a `kernel32.dll` para comunicaciones serie.
class _Kernel32 {
  _Kernel32(DynamicLibrary lib)
      : _createFile = lib.lookupFunction<
            IntPtr Function(
              Pointer<Utf16>,
              Uint32,
              Uint32,
              Pointer<Void>,
              Uint32,
              Uint32,
              IntPtr,
            ),
            int Function(
              Pointer<Utf16>,
              int,
              int,
              Pointer<Void>,
              int,
              int,
              int,
            )>('CreateFileW'),
        _closeHandle = lib.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
          'CloseHandle',
        ),
        _setupComm = lib.lookupFunction<
            Int32 Function(IntPtr, Uint32, Uint32),
            int Function(int, int, int)>('SetupComm'),
        _purgeComm = lib.lookupFunction<Int32 Function(IntPtr, Uint32), int Function(int, int)>(
          'PurgeComm',
        ),
        _setCommState = lib.lookupFunction<Int32 Function(IntPtr, Pointer<_Dcb>),
            int Function(int, Pointer<_Dcb>)>('SetCommState'),
        _writeFile = lib.lookupFunction<
            Int32 Function(IntPtr, Pointer<Void>, Uint32, Pointer<Uint32>, Pointer<Void>),
            int Function(int, Pointer<Void>, int, Pointer<Uint32>, Pointer<Void>)>(
          'WriteFile',
        ),
        _flushFileBuffers =
            lib.lookupFunction<Int32 Function(IntPtr), int Function(int)>('FlushFileBuffers'),
        _getLastError =
            lib.lookupFunction<Uint32 Function(), int Function()>('GetLastError');

  final int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int) _createFile;
  final int Function(int) _closeHandle;
  final int Function(int, int, int) _setupComm;
  final int Function(int, int) _purgeComm;
  final int Function(int, Pointer<_Dcb>) _setCommState;
  final int Function(int, Pointer<Void>, int, Pointer<Uint32>, Pointer<Void>) _writeFile;
  final int Function(int) _flushFileBuffers;
  final int Function() _getLastError;

  int createFile(
    Pointer<Utf16> path,
    int access,
    int share,
    Pointer<Void> security,
    int creation,
    int flagsAndAttributes,
    int template,
  ) =>
      _createFile(path, access, share, security, creation, flagsAndAttributes, template);

  int closeHandle(int handle) => _closeHandle(handle);

  int setupComm(int handle, int inQueue, int outQueue) => _setupComm(handle, inQueue, outQueue);

  int purgeComm(int handle, int flags) => _purgeComm(handle, flags);

  int setCommState(int handle, Pointer<_Dcb> dcb) => _setCommState(handle, dcb);

  int writeFile(
    int handle,
    Pointer<Void> buffer,
    int length,
    Pointer<Uint32> written,
    Pointer<Void> overlapped,
  ) =>
      _writeFile(handle, buffer, length, written, overlapped);

  int flushFileBuffers(int handle) => _flushFileBuffers(handle);

  int lastError() => _getLastError();
}
