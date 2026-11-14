import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'providers.dart';
import '../core/routing/app_router.dart';
import '../core/theme/app_theme.dart';

class SaturdayFutsalApp extends ConsumerStatefulWidget {
  const SaturdayFutsalApp({super.key});
  @override
  ConsumerState<SaturdayFutsalApp> createState() => _SaturdayFutsalAppState();
}

class _SaturdayFutsalAppState extends ConsumerState<SaturdayFutsalApp>
    with WidgetsBindingObserver {
  bool _checkpointBusy = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Future.microtask(_checkpoint);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _checkpoint();
  }

  Future<void> _checkpoint() async {
    if (_checkpointBusy || !mounted || ref.read(maintenanceProvider)) {
      return;
    }
    _checkpointBusy = true;
    try {
      await (await ref.read(
        matchRepositoryProvider.future,
      )).checkpointRunning();
      if (mounted) {
        ref.read(timerPersistenceErrorProvider.notifier).state = false;
        refreshData(ref);
      }
    } catch (_) {
      if (mounted) {
        ref.read(timerPersistenceErrorProvider.notifier).state = true;
      }
    } finally {
      _checkpointBusy = false;
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    title: 'Saturday Futsal',
    debugShowCheckedModeBanner: false,
    theme: buildTheme(),
    routerConfig: appRouter,
    builder: (context, child) {
      final busy = ref.watch(maintenanceProvider);
      return PopScope(
        canPop: !busy,
        child: Stack(
          children: [
            if (child != null) child,
            if (busy) ...[
              const ModalBarrier(dismissible: false, color: Color(0xDD08110E)),
              const Center(
                child: Card(
                  child: Padding(
                    padding: EdgeInsets.all(28),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 20),
                        Text('Safely preparing local data…'),
                        SizedBox(height: 8),
                        Text('Keep Saturday Futsal open until this finishes.'),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      );
    },
  );
}
