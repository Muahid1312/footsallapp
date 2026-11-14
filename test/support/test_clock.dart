import 'package:saturday_futsal/features/matches/domain/match.dart';

class TestMatchClock implements MatchClock {
  TestMatchClock({
    this.runtimeId = 'process-a',
    this.wallMillis = 1800000000000,
    this.tickMillis = 0,
  });
  @override
  final String runtimeId;
  @override
  int wallMillis;
  @override
  int tickMillis;
  @override
  Future<void> synchronize() async {}
  void advance(int millis) {
    wallMillis += millis;
    tickMillis += millis;
  }
}
