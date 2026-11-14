import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import '../domain/match.dart';

/// Android elapsedRealtime includes deep sleep. Stopwatch alone may exclude it.
/// Recalibrate on reads/lifecycle transitions, extrapolate between native samples,
/// and use UTC timestamps only as a reviewed candidate after process death.
class SystemMatchClock implements MatchClock {
  static const _channel = MethodChannel('saturday_futsal/clock');
  final _watch = Stopwatch()..start();
  int _baseTick = 0, _sampleTick = 0;
  @override
  final String runtimeId = const Uuid().v4();
  @override
  int get wallMillis => DateTime.now().millisecondsSinceEpoch;
  @override
  int get tickMillis => _baseTick + _watch.elapsedMilliseconds - _sampleTick;
  @override
  Future<void> synchronize() async {
    if (!Platform.isAndroid) {
      return;
    }
    final nativeTick = await _channel.invokeMethod<int>('elapsedRealtime');
    if (nativeTick == null) {
      throw StateError('Android monotonic clock is unavailable.');
    }
    final current = tickMillis;
    _baseTick = math.max(nativeTick, current);
    _sampleTick = _watch.elapsedMilliseconds;
  }
}
