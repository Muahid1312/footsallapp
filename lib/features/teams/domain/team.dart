class SessionTeam {
  const SessionTeam({
    required this.id,
    required this.sessionId,
    required this.name,
    required this.colorValue,
    this.captainPlayerId,
    required this.playerIds,
  });
  final String id;
  final String sessionId;
  final String name;
  final int colorValue;
  final String? captainPlayerId;
  final List<String> playerIds;
}
