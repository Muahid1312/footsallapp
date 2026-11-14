class FutsalSession {
  const FutsalSession({
    required this.id,
    required this.date,
    required this.locationName,
    required this.matchDurationSeconds,
    required this.rotationMode,
    required this.status,
    required this.createdAt,
  });
  final String id;
  final DateTime date;
  final String locationName;
  final int matchDurationSeconds;
  final String rotationMode;
  final String status;
  final DateTime createdAt;
  factory FutsalSession.fromRow(Map<String, dynamic> r) => FutsalSession(
    id: r['id'] as String,
    date: DateTime.fromMillisecondsSinceEpoch(r['date'] as int, isUtc: true),
    locationName: r['location_name'] as String,
    matchDurationSeconds: r['match_duration_seconds'] as int,
    rotationMode: r['rotation_mode'] as String,
    status: r['status'] as String,
    createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
  );
}
