import 'package:flutter/material.dart';
import 'screens/vm_list_screen.dart';

void main() {
  runApp(const QemuHmosApp());
}

class QemuHmosApp extends StatelessWidget {
  const QemuHmosApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'QEMU for HarmonyOS',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const VmListScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}
