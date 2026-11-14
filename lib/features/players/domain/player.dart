class Player {
  const Player({
    required this.id,
    required this.name,
    this.photoPath,
    required this.preferredPosition,
    this.jerseyNumber,
    required this.skillRating,
    required this.createdAt,
    required this.updatedAt,
    this.isArchived = false,
    this.secondaryPosition,
    this.goalkeeperEligible = false,
    this.preferredFoot = 'unknown',
  });
  final String id;
  final String name;
  final String? photoPath;
  final String preferredPosition;
  final int? jerseyNumber;
  final int skillRating;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool isArchived;
  final String? secondaryPosition;
  final bool goalkeeperEligible;
  final String preferredFoot;

  factory Player.fromRow(Map<String, dynamic> row) => Player(
    id: row['id'] as String,
    name: row['name'] as String,
    photoPath: row['photo_path'] as String?,
    preferredPosition: row['preferred_position'] as String,
    jerseyNumber: row['jersey_number'] as int?,
    skillRating: row['skill_rating'] as int,
    createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
    isArchived: row['is_archived'] == 1,
    secondaryPosition: row['secondary_position'] as String?,
    goalkeeperEligible: row['goalkeeper_eligible'] == 1,
    preferredFoot: row['preferred_foot'] as String? ?? 'unknown',
  );
}
