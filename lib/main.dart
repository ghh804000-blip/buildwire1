import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_state.dart';
import 'ui/home.dart';
import 'ui/theme.dart';
import 'ui/workspace.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    final inter = await rootBundle.loadString('assets/fonts/Inter-OFL.txt');
    yield LicenseEntryWithLineBreaks(const ['Inter'], inter);
    final barlow = await rootBundle.loadString('assets/fonts/BarlowCondensed-OFL.txt');
    yield LicenseEntryWithLineBreaks(const ['Barlow Condensed'], barlow);
    final symbols = await rootBundle.loadString('assets/licenses/QElectroTech-ELEMENTS.LICENSE');
    yield LicenseEntryWithLineBreaks(const ['QElectroTech elements'], symbols);
  });
  final prefs = await SharedPreferences.getInstance();
  final defs = await loadDeviceDefs();
  runApp(BuildWireApp(app: AppState(defs, prefs)));
}

class BuildWireApp extends StatelessWidget {
  const BuildWireApp({super.key, required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) => MaterialApp(
        title: 'BuildWire',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(app.dark),
        locale: const Locale('id'),
        supportedLocales: const [Locale('id')],
        localizationsDelegates: const [GlobalMaterialLocalizations.delegate, GlobalWidgetsLocalizations.delegate, GlobalCupertinoLocalizations.delegate],
        home: AnimatedSwitcher(
          duration: const Duration(milliseconds: 350),
          child: app.showHome ? HomeScreen(key: const ValueKey('home-screen'), app: app) : Workspace(key: const ValueKey('workspace'), app: app),
        ),
      ),
    );
  }
}
