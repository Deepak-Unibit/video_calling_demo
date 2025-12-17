import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:video_calling_demo/home.dart';
import 'package:video_calling_demo/register.dart';

import 'auth.service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  Get.put<AuthService>(AuthService());
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      title: 'Flutter Demo',
      debugShowCheckedModeBanner: false, // Disable the debug banner
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: HomePage(),
    );
  }
}