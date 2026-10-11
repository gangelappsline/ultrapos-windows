import 'dart:math';

/// Política de reintentos con **retroceso exponencial + jitter**.
///
/// Por qué jitter (aleatoriedad): si la nube cae a las 14:00 y hay 40 cajas
/// reintentando cada 30 s en sincronía perfecta, el servidor recibe un pico
/// coordinado y vuelve a caer ("thundering herd"). Con jitter del ±20 % los
/// reintentos se reparten y el backend respira.
///
/// Curva por defecto: 3 s → 6 s → 12 s → 24 s → 48 s → 96 s → 192 s → 384 s
/// (tope de 15 min). Un POS que estuvo sin internet toda la mañana converge en
/// unos pocos minutos sin saturar nada.
class BackoffPolicy {
  const BackoffPolicy({
    this.base = const Duration(seconds: 3),
    this.max = const Duration(minutes: 15),
    this.multiplier = 2.0,
    this.jitterRatio = 0.2,
    this.maxAttempts = 12,
    Random? random,
  }) : _random = random;

  final Duration base;
  final Duration max;
  final double multiplier;

  /// Variación aleatoria aplicada al intervalo (±[jitterRatio]).
  final double jitterRatio;

  /// Tras agotar los intentos la operación se marca `failed` y se avisa al
  /// administrador: preferimos un error visible a un reintento infinito que
  /// consuma CPU y batería para siempre.
  final int maxAttempts;

  final Random? _random;

  Random get _rng => _random ?? _sharedRandom;
  static final Random _sharedRandom = Random();

  /// Retraso para el intento número [attempt] (0 = primer reintento).
  Duration delayFor(int attempt) {
    final int exponent = attempt.clamp(0, 20);
    final double raw = base.inMilliseconds * pow(multiplier, exponent).toDouble();
    final double capped = min(raw, max.inMilliseconds.toDouble());
    final double jitter = capped * jitterRatio * (_rng.nextDouble() * 2 - 1);
    final double finalMs = (capped + jitter).clamp(500, max.inMilliseconds.toDouble());
    return Duration(milliseconds: finalMs.round());
  }

  bool shouldGiveUp(int attempt) => attempt >= maxAttempts;

  /// Segundos hasta el siguiente intento, para mostrar en la UI.
  int secondsUntil(int attempt) => delayFor(attempt).inSeconds;

  /// Configuración recomendada para el POS (idéntica al valor por defecto de
  /// [AppConfig]; se expone aquí para poder ajustarla desde los ajustes).
  static const BackoffPolicy standard = BackoffPolicy();
}

/// Calcula la foto completa de reintentos de un lote (para registro y UI).
class RetryPlan {
  const RetryPlan({required this.opId, required this.attempt, required this.delay, required this.giveUp});

  final String opId;
  final int attempt;
  final Duration delay;
  final bool giveUp;

  static RetryPlan forOperation({
    required String opId,
    required int nextAttempt,
    required BackoffPolicy policy,
  }) =>
      RetryPlan(
        opId: opId,
        attempt: nextAttempt,
        delay: policy.delayFor(nextAttempt),
        giveUp: policy.shouldGiveUp(nextAttempt),
      );
}
