import 'package:flutter/material.dart';

void main() => runApp(const ValmetApp());

class ValmetApp extends StatelessWidget {
  const ValmetApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Valmet Field App',
      home: Scaffold(
        appBar: AppBar(title: const Text('Valmet Field App')),
        body: const Center(child: Text('Valmet Hackathon')),
      ),
    );
  }
}
