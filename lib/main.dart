import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ads.dart';
import 'localization.dart';
import 'screens/home.dart';

const _languageKey = 'app-language';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  String? language;
  try {
    language = await SharedPreferencesAsync().getString(_languageKey);
  } on PlatformException {
    // The device locale remains available when preferences cannot be read.
  }
  runApp(MyApp(initialLanguage: language));
  WidgetsBinding.instance.addPostFrameCallback(
    (_) => unawaited(initializeAds()),
  );
}

const paper = Color(0xFFFFFDF6);
const ink = Color(0xFF36332D);
const accent = Color(0xFF94432B);

class MyApp extends StatefulWidget {
  const MyApp({super.key, this.initialLanguage});

  final String? initialLanguage;

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late String? _language =
      supportedLanguages.containsKey(widget.initialLanguage)
      ? widget.initialLanguage
      : null;
  Future<void> _languageWrite = Future<void>.value();

  void _changeLanguage(String? language) {
    setState(() => _language = language);
    final preferences = SharedPreferencesAsync();
    _languageWrite = _languageWrite.then((_) async {
      try {
        if (language == null) {
          await preferences.remove(_languageKey);
        } else {
          await preferences.setString(_languageKey, language);
        }
      } on PlatformException catch (error) {
        debugPrint('Could not store app language: ${error.code}');
      }
    });
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    onGenerateTitle: (context) => languageOf(context) == 'ko' ? '꼬미' : 'Kkomi',
    debugShowCheckedModeBanner: false,
    locale: supportedLocales
        .where((locale) => locale.toLanguageTag() == _language)
        .firstOrNull,
    supportedLocales: supportedLocales,
    localeListResolutionCallback: resolveLocale,
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: ThemeData(
      fontFamily: 'Pretendard',
      fontFamilyFallback: const ['Noto Sans CJK'],
      colorScheme: ColorScheme.fromSeed(
        seedColor: accent,
        primary: accent,
        surface: Colors.white,
        onSurface: ink,
      ),
      scaffoldBackgroundColor: paper,
      popupMenuTheme: const PopupMenuThemeData(
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        modalBackgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: paper,
        foregroundColor: ink,
        surfaceTintColor: Colors.transparent,
        systemOverlayStyle: SystemUiOverlayStyle.dark,
      ),
    ),
    home: Home(language: _language, onLanguageChanged: _changeLanguage),
  );
}
