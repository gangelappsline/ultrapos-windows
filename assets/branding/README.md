# Carpeta de marca
#
# `pubspec.yaml` declara `assets/branding/`, así que la carpeta DEBE existir o
# `flutter build` falla. Aquí van los archivos de identidad visual:
#
#   ultrapos_logo.png     Logo principal (512x512, fondo transparente).
#                         Se usa en el encabezado del ticket PDF y en el
#                         instalador (assets del runner de Windows).
#   ultrapos.ico          Icono del ejecutable y de la ventana (256x256 multi-
#                         resolución: 16/32/48/64/128/256). Se copia a
#                         windows/runner/resources/app_icon.ico con
#                         tool/setup_windows.ps1.
#   ultrapos_mark.png     Marca reducida (solo el símbolo) para la barra de
#                         título propia y la pantalla de acceso (128x128).
#
# Paleta oficial (usar exactamente estos valores):
#   Azul profundo  #0A2A4A   Cyan de acción  #00AEEF
#   Naranja cobro  #FF6B00   Fondo claro      #F5F7FA
#   Rojo de error  #E53935
#
# Mientras estos archivos no existan, la aplicación funciona igual: la interfaz
# sustituye el logo por el nombre del negocio y el runner usa el icono por
# defecto de Flutter.
