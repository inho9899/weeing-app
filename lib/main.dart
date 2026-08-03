import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:permission_handler/permission_handler.dart';

import 'firebase_options.dart';
import 'screens/config/config_screen.dart';
import 'utils/alert_notifications.dart';

/// 백그라운드/종료 상태에서 수신할 때 호출되는 handler.
///
/// @pragma('vm:entry-point')가 없으면 release 빌드에서 트리쉐이킹으로 이 함수가
/// 제거될 수 있어, 앱이 완전히 종료된 상태에서는 이 핸들러 자체가 안 불릴 수
/// 있다 (디버그 빌드에서는 증상이 안 보여서 놓치기 쉽다).
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  print('BG message: ${message.messageId}');
  print('BG data   : ${message.data}');
  await AlertNotifications.show(message);
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
    await FirebaseMessaging.instance.getToken();
    // print('[DEBUG] FCM 토큰: $token');
  } catch (e) {
    // print('[ERROR] FCM 토큰 획득 실패: $e');
  }

  await AlertNotifications.init();

  // 백그라운드 FCM 전달이 배터리 최적화로 막히지 않도록 예외를 요청한다 —
  // 없으면 Doze/제조사 배터리 관리가 data-only 메시지를 지연·차단해서
  // 알람이 포그라운드에서만 오는 것처럼 보인다.
  try {
    if (await Permission.ignoreBatteryOptimizations.isDenied) {
      await Permission.ignoreBatteryOptimizations.request();
    }
  } catch (e) {
    // print('[ERROR] 배터리 최적화 예외 요청 실패: $e');
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
