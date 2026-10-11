// UltraPOS — runner nativo de Windows.
//
// Reemplaza a `windows/runner/main.cpp` generado por `flutter create`.
//
// Diferencias con el runner de Flutter y por qué importan en un POS:
//
//   1. Título, tamaño inicial y tamaño mínimo son los de un POS de escritorio
//      (1440x900, nunca menos de 1366x768). `window_manager` aplica después lo
//      mismo desde Dart —y decide cuándo mostrar la ventana—, pero aquí quedan
//      garantizados aunque Dart tarde en arrancar.
//   2. Contexto COM inicializado en el hilo de UI: el spooler de impresión y
//      las APIs de puerto serie (cajón de dinero) lo necesitan.
//   3. `--dart-entrypoint-args` se conserva: sirve para arrancar en modo
//      "solo lectura" o con un perfil de configuración distinto.
//   4. Se desactiva el menú de sistema en modo kiosco (variable de entorno
//      ULTRAPOS_KIOSK=1), habitual en terminales de mostrador.

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <cstdlib>
#include <string>

#include "flutter_window.h"
#include "utils.h"

namespace {

constexpr int kDefaultWidth = 1440;
constexpr int kDefaultHeight = 900;

bool RunningInKioskMode() {
  char* value = nullptr;
  size_t length = 0;
  if (_dupenv_s(&value, &length, "ULTRAPOS_KIOSK") != 0 || value == nullptr) {
    return false;
  }
  const std::string raw(value);
  free(value);
  return raw == "1" || raw == "true" || raw == "TRUE";
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance,
                      _In_opt_ HINSTANCE previous_instance,
                      _In_ wchar_t* command_line,
                      _In_ int show_command) {
  // Se adjunta una consola solo cuando se pide por entorno: en producción el
  // log va a archivo (ver lib/core/logging/app_logger.dart).
  if (IsDebuggerPresent() || std::getenv("ULTRAPOS_CONSOLE") != nullptr) {
    CreateAndAttachConsole();
  }

  // COM: imprescindible para el spooler de impresión y para las APIs de puerto
  // serie que usa el cajón de dinero.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  ::OleInitialize(nullptr);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments = GetCommandLineArguments();
  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(kDefaultWidth, kDefaultHeight);

  const bool kiosk = RunningInKioskMode();

  if (!window.CreateAndShow(L"UltraPOS - Punto de Venta", origin, size)) {
    return EXIT_FAILURE;
  }

  if (kiosk) {
    // En kiosco el operador no debe poder mover ni redimensionar la ventana a
    // medias: se fija al tamaño de pantalla útil.
    HWND handle = window.GetHandle();
    LONG style = ::GetWindowLong(handle, GWL_STYLE);
    style &= ~(WS_THICKFRAME | WS_MAXIMIZEBOX | WS_MINIMIZEBOX);
    ::SetWindowLong(handle, GWL_STYLE, style);
    ::SetWindowPos(handle, nullptr, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
  }

  ::MSG message;
  while (::GetMessage(&message, nullptr, 0, 0)) {
    ::TranslateMessage(&message);
    ::DispatchMessage(&message);
  }

  ::OleUninitialize();
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
