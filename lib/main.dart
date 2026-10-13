import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'core/models.dart';
import 'core/store.dart';
import 'core/local_preview.dart';
import 'features/design.dart';
import 'features/home.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = AppStore();
  await store.load();
  const useLocalOpencodeServer =
      bool.fromEnvironment('USE_LOCAL_OPENCODE_SERVER');
  final localServerPassword = kDebugMode && useLocalOpencodeServer
      ? await loadLocalPreviewPassword(
          isIOS: Platform.isIOS,
          processPassword:
              Platform.environment['REMOTE_OPENCODE_SERVER_PASSWORD'],
          readNativePassword: () => const MethodChannel(
            'remote_dev/local_preview',
          ).invokeMethod<String>('localSimulatorPassword'),
        )
      : null;
  if (localServerPassword != null && localServerPassword.isNotEmpty) {
    await store.putMachine(
      Machine(
        id: 'local-simulator',
        name: 'Este Mac · Local',
        url: 'http://127.0.0.1:4096',
        username: 'opencode',
        password: localServerPassword,
      ),
    );
  }
  runApp(RemoteDevApp(store: store));
}

class RemoteDevApp extends StatelessWidget {
  final AppStore store;
  const RemoteDevApp({super.key, required this.store});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Remoto',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          colorScheme: ColorScheme.fromSeed(
            seedColor: AppColors.accent,
            brightness: Brightness.dark,
          ).copyWith(
            primary: AppColors.accent,
            onPrimary: AppColors.accentInk,
            secondary: AppColors.accent,
            surface: AppColors.surface,
            onSurface: AppColors.ink,
            outline: AppColors.outline,
            outlineVariant: AppColors.outline,
            error: AppColors.danger,
          ),
          scaffoldBackgroundColor: AppColors.canvas,
          appBarTheme: const AppBarTheme(
            backgroundColor: AppColors.canvas,
            foregroundColor: AppColors.ink,
            surfaceTintColor: Colors.transparent,
            titleSpacing: 20,
          ),
          cardTheme: CardThemeData(
            color: AppColors.surface,
            elevation: 0,
            margin: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: appRadius,
              side: const BorderSide(color: AppColors.outline),
            ),
          ),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: AppColors.surfaceRaised,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: AppColors.outline),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: AppColors.accent, width: 1.4),
            ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
          ),
          navigationBarTheme: NavigationBarThemeData(
            backgroundColor: AppColors.surface,
            indicatorColor: AppColors.accentSoft,
            elevation: 0,
            labelTextStyle: WidgetStateProperty.resolveWith((states) {
              return TextStyle(
                color: states.contains(WidgetState.selected)
                    ? AppColors.accent
                    : AppColors.muted,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              );
            }),
          ),
          floatingActionButtonTheme: const FloatingActionButtonThemeData(
            backgroundColor: AppColors.accent,
            foregroundColor: AppColors.accentInk,
            extendedTextStyle: TextStyle(fontWeight: FontWeight.w700),
          ),
          dividerColor: AppColors.outline,
        ),
        home: HomeScreen(store: store),
      );
}
