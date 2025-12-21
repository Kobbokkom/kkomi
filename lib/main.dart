import 'package:flutter/material.dart';
import 'screens/document_viewer.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'kkomi - 문서 뷰어',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const DocumentViewer(),
      debugShowCheckedModeBanner: false,
    );
  }
}
