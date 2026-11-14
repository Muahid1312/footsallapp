import '../../../core/database/app_database.dart';
import '../domain/player_csv.dart';

class PlayerImportRepository {
  PlayerImportRepository(this.db);
  final AppDatabase db;
  Future<int> apply(List<PlayerImportRow> rows) => db.transaction(() async {
    final selected = rows.where((r) => r.action != 'skip').toList();
    if (selected.isEmpty) {
      throw ArgumentError('Choose at least one valid record.');
    }
    final names = <String>{}, updated = <String>{};
    final existing = await db.players(includeArchived: true),
        byId = {for (final player in existing) player.id: player},
        existingNames = existing.map((p) => playerNameKey(p.name)).toSet();
    var count = 0;
    for (final r in selected) {
      if (r.error != null ||
          !['create', 'update'].contains(r.action) ||
          !names.add(playerNameKey(r.name))) {
        throw ArgumentError('Select only one valid record per player name.');
      }
      if (r.action == 'create') {
        if (!existingNames.add(playerNameKey(r.name))) {
          throw StateError(
            'A matching player now exists. Rebuild the preview to avoid duplicates.',
          );
        }
        await db.savePlayer(
          name: r.name,
          position: r.position,
          skillRating: 5,
          jerseyNumber: r.jersey,
          preferredFoot: r.foot,
          goalkeeperEligible: r.position == 'Goalkeeper',
        );
      } else {
        if (r.target == null || !updated.add(r.target!)) {
          throw ArgumentError(
            'Choose a unique existing player for each update.',
          );
        }
        final old = byId[r.target!];
        final before = r.duplicates.where((p) => p.id == r.target).firstOrNull;
        if (old == null ||
            before == null ||
            old.updatedAt != before.updatedAt ||
            old.name != before.name ||
            old.preferredPosition != before.preferredPosition ||
            old.preferredFoot != before.preferredFoot ||
            old.jerseyNumber != before.jerseyNumber) {
          throw StateError(
            'An existing profile changed. Rebuild the import preview.',
          );
        }
        final position = r.hasPosition ? r.position : old.preferredPosition;
        await db.savePlayer(
          id: old.id,
          name: r.name,
          position: position,
          skillRating: old.skillRating,
          photoPath: old.photoPath,
          jerseyNumber: r.jersey ?? old.jerseyNumber,
          preferredFoot: r.hasFoot ? r.foot : old.preferredFoot,
          secondaryPosition: old.secondaryPosition == position
              ? null
              : old.secondaryPosition,
          updateSecondaryPosition: true,
          goalkeeperEligible: old.goalkeeperEligible,
        );
      }
      count++;
    }
    return count;
  });
}
