import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'presentation/boma/boma_screen.dart';
import 'presentation/council/council_screen.dart';
import 'presentation/raid/raid_screen.dart';
import 'presentation/boma/grazing_drill_sheet.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const ProviderScope(child: BomaApp()));
}

class BomaApp extends StatelessWidget {
  const BomaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Boma: Pastoralist Language Strategy',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF8B5E34)),
        scaffoldBackgroundColor: const Color(0xFFF3E6C9), // dry savanna sand
      ),
      home: const RootShell(),
      // The Daily Grazing Drill (SM-2 flashcards) rides above the kraal.
      routes: {GrazingDrillSheet.routeName: (_) => const GrazingDrillSheet()},
    );
  }
}

/// Bottom-nav shell: Kraal (home) · Council (review) · Raid (war).
class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final pages = const [BomaScreen(), CouncilScreen(), RaidScreen()];
    return Scaffold(
      body: IndexedStack(index: _tab, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.park_outlined), label: 'Boma'),
          NavigationDestination(
              icon: Icon(Icons.gavel_outlined), label: 'Council'),
          NavigationDestination(
              icon: Icon(Icons.flag_outlined), label: 'Raid'),
        ],
      ),
    );
  }
}
