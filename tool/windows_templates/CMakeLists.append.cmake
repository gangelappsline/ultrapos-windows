# ---------------------------------------------------------------------------
# UltraPOS — parches de CMake para el runner de Windows.
#
# Este bloque NO reemplaza a `windows/CMakeLists.txt` (el generado por Flutter
# cambia entre versiones): `tool/setup_windows.ps1` lo AÑADE al final del
# archivo generado, una sola vez. Al ejecutarse después de `add_subdirectory`
# ya existe el target `${BINARY_NAME}`, por lo que se pueden añadir opciones de
# compilación sin tocar la plantilla.
#
# Qué resuelve:
#   1. Metadatos de versión del ejecutable (para el instalador y el soporte).
#   2. Un error claro si se pide cifrado de base de datos sin OpenSSL, en lugar
#      del fallo críptico de CMake ("Could NOT find OpenSSL").
#   3. pdfium fijable por entorno, útil en equipos con proxy o sin internet.
# ---------------------------------------------------------------------------

if(NOT DEFINED ULTRAPOS_VERSION)
  set(ULTRAPOS_VERSION "1.0.0")
endif()

set(ULTRAPOS_PRODUCT_NAME "UltraPOS" CACHE STRING "Nombre visible del producto")
set(ULTRAPOS_COMPANY_NAME "UltraPOS" CACHE STRING "Empresa del producto")

if(TARGET ${BINARY_NAME})
  target_compile_definitions(${BINARY_NAME} PRIVATE
    ULTRAPOS_VERSION="${ULTRAPOS_VERSION}")
  target_compile_options(${BINARY_NAME} PRIVATE /utf-8)
  target_compile_features(${BINARY_NAME} PRIVATE cxx_std_17)
endif()

if(DEFINED ULTRAPOS_DB_ENCRYPTION AND ULTRAPOS_DB_ENCRYPTION)
  if(NOT DEFINED OPENSSL_ROOT_DIR)
    message(FATAL_ERROR
      "ULTRAPOS_DB_ENCRYPTION está activo y falta OPENSSL_ROOT_DIR.\n"
      "  Instale OpenSSL 3.x (vcpkg install openssl:x64-windows) y compile con\n"
      "  --cmake-args=\"-DOPENSSL_ROOT_DIR=C:/Program Files/OpenSSL-Win64\".\n"
      "  Detalles en docs/WINDOWS_SETUP.md.")
  endif()
  if(TARGET ${BINARY_NAME})
    target_compile_definitions(${BINARY_NAME} PRIVATE ULTRAPOS_ENABLE_OPENSSL=1)
  endif()
endif()

if(DEFINED PDFIUM_VERSION)
  # `printing` descarga pdfium; se puede fijar la versión para mirrors internos.
  set(PDFIUM_VERSION "${PDFIUM_VERSION}" CACHE STRING "Versión de pdfium" FORCE)
endif()
