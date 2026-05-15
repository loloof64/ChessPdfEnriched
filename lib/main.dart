import 'package:flutter/material.dart';
import 'screens/home_screen.dart';

void main() {
  runApp(const ChessPdfApp());
}

class ChessPdfApp extends StatelessWidget {
  const ChessPdfApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Chess PDF Enriched',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey),
      ),
      home: const HomeScreen(),
    );
  }
}
