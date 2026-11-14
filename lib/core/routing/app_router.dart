import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../features/dashboard/presentation/dashboard_screen.dart';
import '../../features/players/presentation/players_screen.dart';
import '../../features/players/presentation/player_form_screen.dart';
import '../../features/players/presentation/player_details_screen.dart';
import '../../features/sessions/presentation/sessions_screen.dart';
import '../../features/sessions/presentation/session_form_screen.dart';
import '../../features/sessions/presentation/session_details_screen.dart';
import '../../features/teams/presentation/team_builder_screen.dart';
import '../../features/matches/presentation/match_center_screen.dart';
import '../../features/matches/presentation/match_schedule_screen.dart';
import '../../features/matches/presentation/match_summary_screen.dart';
import '../../features/competitions/presentation/competition_form_screen.dart';
import '../../features/competitions/presentation/competition_screen.dart';
import '../../features/teams/presentation/balance_preview_screen.dart';
import '../../features/statistics/presentation/player_analytics_screen.dart';
import '../../features/statistics/presentation/leaderboards_screen.dart';
import '../../features/statistics/presentation/session_mvp_screen.dart';
import '../../features/settings/presentation/settings_screen.dart';
import '../../features/importing/presentation/player_import_screen.dart';
import '../../features/posters/presentation/winner_poster_screen.dart';

final appRouter = GoRouter(
  routes: [
    GoRoute(path: '/settings', builder: (_, s) => const SettingsScreen()),
    GoRoute(
      path: '/players/import',
      builder: (_, s) => const PlayerImportScreen(),
    ),
    GoRoute(
      path: '/competitions/:id/poster',
      builder: (_, s) =>
          WinnerPosterScreen(competitionId: s.pathParameters['id']!),
    ),
    GoRoute(
      path: '/sessions/:id/balance',
      builder: (_, s) =>
          BalancePreviewScreen(sessionId: s.pathParameters['id']!),
    ),
    GoRoute(
      path: '/players/:id/analytics',
      builder: (_, s) =>
          PlayerAnalyticsScreen(playerId: s.pathParameters['id']!),
    ),
    GoRoute(
      path: '/statistics',
      builder: (_, s) =>
          LeaderboardsScreen(sessionId: s.uri.queryParameters['session']),
    ),
    GoRoute(
      path: '/sessions/:id/mvp',
      builder: (_, s) => SessionMvpScreen(sessionId: s.pathParameters['id']!),
    ),

    GoRoute(
      path: '/sessions/:sid/competition/:id/settings',
      builder: (_, s) => CompetitionFormScreen(
        sessionId: s.pathParameters['sid']!,
        competitionId: s.pathParameters['id']!,
      ),
    ),
    GoRoute(
      path: '/sessions/:id/competition/new',
      builder: (_, s) =>
          CompetitionFormScreen(sessionId: s.pathParameters['id']!),
    ),
    GoRoute(
      path: '/competitions/:id',
      builder: (_, s) => CompetitionScreen(id: s.pathParameters['id']!),
    ),
    ShellRoute(
      builder: (context, state, child) =>
          _AppShell(location: state.uri.path, child: child),
      routes: [
        GoRoute(path: '/', builder: (_, state) => const DashboardScreen()),
        GoRoute(path: '/players', builder: (_, state) => const PlayersScreen()),
        GoRoute(
          path: '/sessions',
          builder: (_, state) => const SessionsScreen(),
        ),
      ],
    ),
    GoRoute(
      path: '/players/new',
      builder: (_, state) => const PlayerFormScreen(),
    ),
    GoRoute(
      path: '/players/:id/edit',
      builder: (_, state) =>
          PlayerFormScreen(playerId: state.pathParameters['id']!),
    ),
    GoRoute(
      path: '/players/:id',
      builder: (_, state) =>
          PlayerDetailsScreen(id: state.pathParameters['id']!),
    ),
    GoRoute(
      path: '/sessions/new',
      builder: (_, state) => const SessionFormScreen(),
    ),
    GoRoute(
      path: '/sessions/:id/teams',
      builder: (_, state) => TeamBuilderScreen(id: state.pathParameters['id']!),
    ),
    GoRoute(
      path: '/sessions/:id/matches/new',
      builder: (_, state) =>
          MatchScheduleScreen(sessionId: state.pathParameters['id']!),
    ),
    GoRoute(
      path: '/matches/:id/summary',
      builder: (_, state) =>
          MatchSummaryScreen(id: state.pathParameters['id']!),
    ),
    GoRoute(
      path: '/matches/:id',
      builder: (_, state) => MatchCenterScreen(id: state.pathParameters['id']!),
    ),
    GoRoute(
      path: '/sessions/:id',
      builder: (_, state) =>
          SessionDetailsScreen(id: state.pathParameters['id']!),
    ),
  ],
  errorBuilder: (context, state) => Scaffold(
    appBar: AppBar(title: const Text('Page unavailable')),
    body: Center(
      child: FilledButton(
        onPressed: () => context.go('/'),
        child: const Text('Back to dashboard'),
      ),
    ),
  ),
);

class _AppShell extends StatelessWidget {
  const _AppShell({required this.location, required this.child});
  final String location;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final index = location.startsWith('/players')
        ? 1
        : location.startsWith('/sessions')
        ? 2
        : 0;
    return Scaffold(
      body: SafeArea(child: child),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (i) =>
            context.go(['/', '/players', '/sessions'][i]),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.grid_view_rounded),
            label: 'Matchday',
          ),
          NavigationDestination(
            icon: Icon(Icons.groups_2_outlined),
            selectedIcon: Icon(Icons.groups_2),
            label: 'Players',
          ),
          NavigationDestination(
            icon: Icon(Icons.calendar_month_outlined),
            selectedIcon: Icon(Icons.calendar_month),
            label: 'Sessions',
          ),
        ],
      ),
    );
  }
}
