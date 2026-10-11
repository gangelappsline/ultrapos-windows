import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_spacing.dart';
import 'app_typography.dart';

/// Tema Material 3 de UltraPOS, afinado para escritorio Windows.
///
/// Objetivos de diseño:
///  * Se ve nativo, no como una app móvil escalada: densidad compacta,
///    bordes de 1px, sombras discretas, radios 8-12.
///  * El naranja [AppColors.orange] es el dueño absoluto de la acción de venta.
///  * El foco de teclado es siempre visible (operación sin mouse).
abstract final class AppTheme {
  static ThemeData light() {
    const ColorScheme scheme = ColorScheme(
      brightness: Brightness.light,
      primary: AppColors.deepBlue,
      onPrimary: AppColors.white,
      primaryContainer: AppColors.deepBlue100,
      onPrimaryContainer: AppColors.deepBlue,
      secondary: AppColors.cyan,
      onSecondary: AppColors.white,
      secondaryContainer: AppColors.cyanSurface,
      onSecondaryContainer: AppColors.cyanDark,
      tertiary: AppColors.orange,
      onTertiary: AppColors.white,
      tertiaryContainer: AppColors.orangeSurface,
      onTertiaryContainer: AppColors.orangeDark,
      error: AppColors.red,
      onError: AppColors.white,
      errorContainer: AppColors.redSurface,
      onErrorContainer: AppColors.redDark,
      surface: AppColors.white,
      onSurface: AppColors.textPrimary,
      surfaceContainerLowest: AppColors.white,
      surfaceContainerLow: AppColors.grey50,
      surfaceContainer: AppColors.surface,
      surfaceContainerHigh: AppColors.grey100,
      surfaceContainerHighest: AppColors.grey200,
      onSurfaceVariant: AppColors.textSecondary,
      outline: AppColors.grey300,
      outlineVariant: AppColors.border,
      shadow: Color(0x330A2A4A),
      scrim: Color(0x800A2A4A),
      inverseSurface: AppColors.deepBlue,
      onInverseSurface: AppColors.white,
      inversePrimary: AppColors.cyanLight,
    );

    final ThemeData base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.background,
      // Desktop: sin "splash" exagerado ni overscroll móvil.
      splashFactory: InkRipple.splashFactory,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.linux: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.macOS: FadeUpwardsPageTransitionsBuilder(),
        },
      ),
    );

    return base.copyWith(
      textTheme: _textTheme(base.textTheme),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.deepBlue,
        foregroundColor: AppColors.white,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: AppColors.white,
          fontFamilyFallback: AppTypography.fallback,
        ),
        toolbarHeight: AppSpacing.toolbarHeight,
      ),
      cardTheme: CardThemeData(
        color: AppColors.card,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadius.lgAll,
          side: const BorderSide(color: AppColors.border),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.divider,
        thickness: 1,
        space: 1,
      ),
      // --- Botones ---
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          minimumSize: const Size(0, AppSpacing.controlHeight),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          backgroundColor: AppColors.deepBlue,
          foregroundColor: AppColors.white,
          disabledBackgroundColor: AppColors.disabled,
          disabledForegroundColor: AppColors.white,
          elevation: 0,
          textStyle: AppTypography.button,
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.smAll),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, AppSpacing.controlHeight),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          backgroundColor: AppColors.deepBlue,
          foregroundColor: AppColors.white,
          textStyle: AppTypography.button,
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.smAll),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, AppSpacing.controlHeight),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          foregroundColor: AppColors.deepBlue,
          side: const BorderSide(color: AppColors.grey300),
          textStyle: AppTypography.button,
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.smAll),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(0, AppSpacing.controlHeight),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          foregroundColor: AppColors.cyanDark,
          textStyle: AppTypography.button,
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.smAll),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: AppColors.textSecondary,
          highlightColor: AppColors.cyanSurface,
          minimumSize: const Size(36, 36),
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.smAll),
        ),
      ),
      // --- Entradas de texto ---
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.white,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm + 2,
        ),
        hintStyle: AppTypography.body.copyWith(color: AppColors.textHint),
        labelStyle: AppTypography.caption.copyWith(color: AppColors.textSecondary),
        floatingLabelStyle: AppTypography.caption.copyWith(color: AppColors.cyanDark),
        errorStyle: AppTypography.caption.copyWith(color: AppColors.red),
        border: _inputBorder(AppColors.grey300),
        enabledBorder: _inputBorder(AppColors.grey300),
        focusedBorder: _inputBorder(AppColors.cyan, width: 1.6),
        errorBorder: _inputBorder(AppColors.red),
        focusedErrorBorder: _inputBorder(AppColors.red, width: 1.6),
        disabledBorder: _inputBorder(AppColors.grey200),
      ),
      // --- Selección / dropdowns ---
      dropdownMenuTheme: DropdownMenuThemeData(
        textStyle: AppTypography.body,
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          isDense: true,
          fillColor: AppColors.white,
          border: _inputBorder(AppColors.grey300),
          enabledBorder: _inputBorder(AppColors.grey300),
          focusedBorder: _inputBorder(AppColors.cyan, width: 1.6),
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.xsAll),
        side: const BorderSide(color: AppColors.grey400, width: 1.4),
        fillColor: WidgetStateProperty.resolveWith<Color>(
          (Set<WidgetState> states) => states.contains(WidgetState.selected)
              ? AppColors.cyan
              : const Color(0x00000000),
        ),
      ),
      switchTheme: SwitchThemeData(
        trackColor: WidgetStateProperty.resolveWith<Color>(
          (Set<WidgetState> states) => states.contains(WidgetState.selected)
              ? AppColors.cyan
              : AppColors.grey300,
        ),
        thumbColor: const WidgetStatePropertyAll<Color>(AppColors.white),
      ),
      // --- Datos / tablas ---
      dataTableTheme: DataTableThemeData(
        headingTextStyle: AppTypography.label.copyWith(color: AppColors.textSecondary),
        dataTextStyle: AppTypography.table,
        headingRowColor: const WidgetStatePropertyAll<Color>(AppColors.grey50),
        dividerThickness: 1,
        horizontalMargin: AppSpacing.md,
        columnSpacing: AppSpacing.xl,
        headingRowHeight: 40,
        dataRowMinHeight: 38,
        dataRowMaxHeight: 46,
      ),
      // --- Diálogos y modales ---
      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.white,
        surfaceTintColor: const Color(0x00000000),
        elevation: 12,
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.xlAll),
        titleTextStyle: AppTypography.title.copyWith(color: AppColors.textPrimary),
        contentTextStyle: AppTypography.body.copyWith(color: AppColors.textSecondary),
        insetPadding: const EdgeInsets.all(AppSpacing.xxl),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.white,
        surfaceTintColor: Color(0x00000000),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.deepBlue,
        contentTextStyle: AppTypography.body.copyWith(color: AppColors.white),
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.smAll),
        insetPadding: const EdgeInsets.all(AppSpacing.lg),
        width: 460,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: const BoxDecoration(
          color: AppColors.grey900,
          borderRadius: AppRadius.xsAll,
        ),
        textStyle: AppTypography.caption.copyWith(color: AppColors.white),
        waitDuration: const Duration(milliseconds: 400),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: AppColors.cyan,
        linearTrackColor: AppColors.grey100,
        linearMinHeight: 4,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: AppColors.grey100,
        selectedColor: AppColors.deepBlue,
        disabledColor: AppColors.grey200,
        side: BorderSide.none,
        labelStyle: AppTypography.caption.copyWith(color: AppColors.textSecondary),
        secondaryLabelStyle: AppTypography.caption.copyWith(color: AppColors.white),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.xxs,
        ),
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.pillAll),
      ),
      listTileTheme: ListTileThemeData(
        dense: true,
        visualDensity: VisualDensity.compact,
        iconColor: AppColors.textSecondary,
        textColor: AppColors.textPrimary,
        titleTextStyle: AppTypography.bodyStrong,
        subtitleTextStyle: AppTypography.caption.copyWith(color: AppColors.textSecondary),
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.smAll),
        selectedTileColor: AppColors.cyanSurface,
        minVerticalPadding: AppSpacing.sm,
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: AppColors.deepBlue,
        unselectedLabelColor: AppColors.textSecondary,
        labelStyle: AppTypography.bodyStrong,
        unselectedLabelStyle: AppTypography.body,
        indicatorColor: AppColors.cyan,
        indicatorSize: TabBarIndicatorSize.tab,
        dividerColor: AppColors.border,
        overlayColor: const WidgetStatePropertyAll<Color>(AppColors.cyanSurface),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: const WidgetStatePropertyAll<double>(10),
        radius: const Radius.circular(AppRadius.pill),
        thumbColor: WidgetStateProperty.resolveWith<Color>(
          (Set<WidgetState> states) => states.contains(WidgetState.dragged)
              ? AppColors.deepBlue600
              : AppColors.grey300,
        ),
        trackColor: const WidgetStatePropertyAll<Color>(Color(0x00000000)),
        trackBorderColor: const WidgetStatePropertyAll<Color>(Color(0x00000000)),
      ),
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: AppColors.cyan,
        selectionColor: Color(0x3300AEEF),
        selectionHandleColor: AppColors.cyan,
      ),
      // El foco debe ser imposible de perder: operación sin mouse.
      focusColor: const Color(0x1A00AEEF),
      hoverColor: const Color(0x0D00AEEF),
      highlightColor: const Color(0x1400AEEF),
    );
  }

  static OutlineInputBorder _inputBorder(Color color, {double width = 1}) {
    return OutlineInputBorder(
      borderRadius: AppRadius.smAll,
      borderSide: BorderSide(color: color, width: width),
    );
  }

  static TextTheme _textTheme(TextTheme base) {
    return base.copyWith(
      displayLarge: AppTypography.display.copyWith(color: AppColors.textPrimary),
      displayMedium: AppTypography.display.copyWith(color: AppColors.textPrimary),
      headlineMedium: AppTypography.headline.copyWith(color: AppColors.textPrimary),
      titleLarge: AppTypography.title.copyWith(color: AppColors.textPrimary),
      titleMedium: AppTypography.subtitle.copyWith(color: AppColors.textPrimary),
      bodyLarge: AppTypography.body.copyWith(color: AppColors.textPrimary),
      bodyMedium: AppTypography.body.copyWith(color: AppColors.textSecondary),
      bodySmall: AppTypography.caption.copyWith(color: AppColors.textSecondary),
      labelLarge: AppTypography.button.copyWith(color: AppColors.textPrimary),
      labelSmall: AppTypography.label.copyWith(color: AppColors.textSecondary),
    );
  }
}
