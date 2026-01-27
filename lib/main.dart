import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'firebase_options.dart';
import 'screens/config/config_screen.dart';

/// 백그라운드/종료 상태에서 수신할 때 호출되는 handler
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  print('BG message: ${message.messageId}');
  print('BG data   : ${message.data}');
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // print('[DEBUG] main() 시작');
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    // print('[DEBUG] Firebase.initializeApp 성공');
  } catch (e) {
    // print('[ERROR] Firebase.initializeApp 실패: $e');
  }

  // 백그라운드 핸들러 등록
  try {
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
    // print('[DEBUG] FCM 백그라운드 핸들러 등록 성공');
  } catch (e) {
    // print('[ERROR] FCM 백그라운드 핸들러 등록 실패: $e');
  }

  // FCM 토큰 디버깅
  try {
    final token = await FirebaseMessaging.instance.getToken();
    // print('[DEBUG] FCM 토큰: $token');
  } catch (e) {
    // print('[ERROR] FCM 토큰 획득 실패: $e');
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String?>(
      future: FirebaseMessaging.instance.getToken(),
      builder: (context, snapshot) {
        final token = snapshot.data ?? '';
        return MaterialApp(
          title: 'FCM + Device Config',
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
          ),
          home: ConfigScreen(fcmToken: token),
        );
      },
    );
  }
}
