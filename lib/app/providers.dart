import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import '../core/database/app_database.dart';
import '../features/players/data/photo_store.dart';
import '../features/players/domain/player.dart';
import '../features/sessions/domain/session.dart';
import '../features/teams/domain/team.dart';
import '../features/matches/data/match_repository.dart';
import '../features/matches/domain/match.dart';
import '../features/matches/data/system_match_clock.dart';
import '../features/competitions/data/competition_repository.dart';
import '../features/competitions/domain/competition.dart';
import '../features/teams/data/balance_repository.dart';
import '../features/statistics/data/statistics_repository.dart';
import '../features/statistics/domain/statistics.dart';
import '../core/storage/app_storage.dart';
import '../core/storage/device_files.dart';
import '../features/settings/data/settings_repository.dart';
import '../features/backup/data/backup_service.dart';

final storageProvider = FutureProvider<AppStorage>(
  (ref) async => AppStorage(await getApplicationDocumentsDirectory()),
);
final maintenanceProvider = StateProvider<bool>((ref) => false);
final deviceFilesProvider = Provider((ref) => DeviceFiles());
final backupServiceProvider = FutureProvider<BackupService>(
  (ref) async => BackupService(await ref.watch(storageProvider.future)),
);
final settingsProvider = FutureProvider<AppSettings>((ref) async {
  ref.watch(revisionProvider);
  return SettingsRepository(await ref.watch(databaseProvider.future)).load();
});
final databaseProvider = FutureProvider<AppDatabase>((ref) async {
  final directory = await (await ref.watch(storageProvider.future)).active();
  final db = AppDatabase.file(
    File(path.join(directory.path, 'saturday_futsal.sqlite')),
  );
  ref.onDispose(() {
    db.close();
  });
  await db.customSelect('SELECT 1').get();
  return db;
});
final revisionProvider = StateProvider<int>((ref) => 0);
final playersProvider = FutureProvider<List<Player>>((ref) async {
  ref.watch(revisionProvider);
  return (await ref.watch(
    databaseProvider.future,
  )).players(includeArchived: true);
});
final sessionsProvider = FutureProvider<List<FutsalSession>>((ref) async {
  ref.watch(revisionProvider);
  return (await ref.watch(databaseProvider.future)).sessions();
});

class SessionBundle {
  const SessionBundle(
    this.session,
    this.attendees,
    this.teams, {
    this.rosterLocked = false,
  });
  final FutsalSession session;
  final List<Player> attendees;
  final List<SessionTeam> teams;
  final bool rosterLocked;
}

final sessionProvider = FutureProvider.family<SessionBundle?, String>((
  ref,
  id,
) async {
  ref.watch(revisionProvider);
  final db = await ref.watch(databaseProvider.future);
  final session = await db.session(id);
  if (session == null) {
    return null;
  }
  return SessionBundle(
    session,
    await db.attendees(id),
    await db.teams(id),
    rosterLocked: (await db.rows(
      'SELECT id FROM matches WHERE session_id=? LIMIT 1',
      [id],
    )).isNotEmpty,
  );
});
final photoStoreProvider = Provider(
  (ref) => PhotoStore(
    root: () async => (await ref.read(storageProvider.future)).active(),
  ),
);
void refreshData(WidgetRef ref) => ref.read(revisionProvider.notifier).state++;

void retryData(WidgetRef ref) {
  ref.invalidate(databaseProvider);
  refreshData(ref);
}

final matchClockProvider = Provider<MatchClock>((ref) => SystemMatchClock());
final matchRepositoryProvider = FutureProvider<MatchRepository>((ref) async {
  final clock = ref.watch(matchClockProvider);
  final db = await ref.watch(databaseProvider.future);
  await clock.synchronize();
  return MatchRepository(db, clock);
});
final matchProvider = FutureProvider.family<MatchBundle?, String>((
  ref,
  id,
) async {
  ref.watch(revisionProvider);
  return (await ref.watch(matchRepositoryProvider.future)).load(id);
});
final sessionMatchesProvider = FutureProvider.family<List<MatchRecord>, String>(
  (ref, id) async {
    ref.watch(revisionProvider);
    return (await ref.watch(matchRepositoryProvider.future)).forSession(id);
  },
);
final careerProvider = FutureProvider.family<Map<String, int>, String>((
  ref,
  id,
) async {
  ref.watch(revisionProvider);
  return (await ref.watch(matchRepositoryProvider.future)).career(id);
});
final recentFinishedProvider = FutureProvider<MatchBundle?>((ref) async {
  ref.watch(revisionProvider);
  return (await ref.watch(matchRepositoryProvider.future)).recentFinished();
});
final timerPersistenceErrorProvider = StateProvider<bool>((ref) => false);
final balanceRepositoryProvider = FutureProvider<BalanceRepository>(
  (ref) async => BalanceRepository(await ref.watch(databaseProvider.future)),
);
final statisticsRepositoryProvider = FutureProvider<StatisticsRepository>(
  (ref) async => StatisticsRepository(await ref.watch(databaseProvider.future)),
);
final statisticsProvider =
    FutureProvider.family<StatisticsBundle, StatisticsScope>((
      ref,
      scope,
    ) async {
      ref.watch(revisionProvider);
      return (await ref.watch(statisticsRepositoryProvider.future)).load(scope);
    });
final mvpProvider = FutureProvider.family<SessionMvp, String>((ref, id) async {
  ref.watch(revisionProvider);
  return (await ref.watch(statisticsRepositoryProvider.future)).mvp(id);
});
final playerSessionHistoryProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((ref, id) async {
      ref.watch(revisionProvider);
      return (await ref.watch(
        statisticsRepositoryProvider.future,
      )).playerHistory(id);
    });
final ratingHistoryProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((ref, id) async {
      ref.watch(revisionProvider);
      return (await ref.watch(
        statisticsRepositoryProvider.future,
      )).ratingHistory(id);
    });
final competitionRepositoryProvider = FutureProvider<CompetitionRepository>(
  (ref) async => CompetitionRepository(
    await ref.watch(databaseProvider.future),
    ref.watch(matchClockProvider),
  ),
);
final competitionsProvider = FutureProvider.family<List<Competition>, String>((
  ref,
  id,
) async {
  ref.watch(revisionProvider);
  return (await ref.watch(competitionRepositoryProvider.future)).forSession(id);
});
final competitionProvider = FutureProvider.family<CompetitionBundle?, String>((
  ref,
  id,
) async {
  ref.watch(revisionProvider);
  return (await ref.watch(competitionRepositoryProvider.future)).load(id);
});

final correctableCompetitionProvider = FutureProvider.family<String?, String>((
  ref,
  matchId,
) async {
  ref.watch(revisionProvider);
  final db = await ref.watch(databaseProvider.future);
  final rows = await db.rows(
    "SELECT c.id FROM competitions c JOIN competition_fixtures f ON f.competition_id=c.id WHERE f.match_id=? AND c.status='active'",
    [matchId],
  );
  return rows.isEmpty ? null : rows.single['id'] as String;
});
