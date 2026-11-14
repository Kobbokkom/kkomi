import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ads.dart';
import 'screens/home.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
  WidgetsBinding.instance.addPostFrameCallback(
    (_) => unawaited(initializeAds()),
  );
}

const paper = Color(0xFFFFFDF6);
const ink = Color(0xFF36332D);
const accent = Color(0xFF94432B);

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '꼬미',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
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
    home: const Home(),
  );
}
