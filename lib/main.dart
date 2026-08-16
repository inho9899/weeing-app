import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:permission_handler/permission_handler.dart';

import 'firebase_options.dart';
import 'gateway/gateway.dart';
import 'screens/config/config_screen.dart';
import 'screens/setup/server_setup_screen.dart';
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

  // 게이트웨이 주소를 메모리로 올린다. 저장된 값이 없으면 아래 MyApp 이
  // ConfigScreen 대신 ServerSetupScreen 을 띄운다 — 주소가 없으면 PC 추가부터
  // 아무것도 할 수 없으므로 여기서 막는 게 맞다.
  await Gateway.ensureLoaded();

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

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  /// main() 의 ensureLoaded 결과. 설정 화면에서 저장이 끝나면 true 로 바뀐다.
  bool _configured = Gateway.isConfigured;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FCM + Device Config',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      ),
      // 주소가 없으면 설정 화면부터. FCM 토큰은 여기선 필요 없으므로 기다리지 않는다.
      home: _configured
          ? FutureBuilder<String?>(
              future: FirebaseMessaging.instance.getToken(),
              builder: (context, snapshot) {
                return ConfigScreen(fcmToken: snapshot.data ?? '');
              },
            )
          : ServerSetupScreen(
              onSaved: () => setState(() => _configured = true),
            ),
    );
  }
}
