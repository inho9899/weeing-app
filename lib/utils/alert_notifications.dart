import 'dart:typed_data';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// severity(low/middle/high)별로 다른 알림 채널(중요도/소리/진동)을 골라 로컬
/// 알림으로 띄운다.
///
/// FCM 메시지를 `notification` 필드로 보내면 백그라운드/종료 상태에서는 OS가
/// 앱 코드를 거치지 않고 기본 채널로 자동 표시해버려서 severity별 분기가
/// 불가능하다. 그래서 서버(cloudfare/route/message/receive_message/fcm_client.py)가
/// `data`만 보내는 방식으로 바뀌었고, 포그라운드([config_screen.dart]의
/// onMessage)와 백그라운드/종료 상태([main.dart]의 background handler) 양쪽 다
/// 이 클래스를 통해 직접 표시한다.
class AlertNotifications {
  AlertNotifications._();

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static final Map<String, ({AndroidNotificationChannel channel, Priority priority})>
      _specs = {
    'low': (
      channel: const AndroidNotificationChannel(
        'alert_low',
        '알림 - 낮음',
        description: '낮은 심각도 알림 (조용히)',
        importance: Importance.low,
        enableVibration: false,
      ),
      priority: Priority.low,
    ),
    'middle': (
      channel: const AndroidNotificationChannel(
        'alert_middle',
        '알림 - 보통',
        description: '보통 심각도 알림',
        importance: Importance.high,
        enableVibration: true,
      ),
      priority: Priority.high,
    ),
    'high': (
      channel: AndroidNotificationChannel(
        'alert_high',
        '알림 - 긴급',
        description: '긴급 심각도 알림 (반복 진동)',
        importance: Importance.max,
        enableVibration: true,
        vibrationPattern: Int64List.fromList([0, 500, 200, 500, 200, 500]),
      ),
      priority: Priority.max,
    ),
  };

  static bool _initialized = false;

  /// 앱 시작 시(포그라운드 isolate)와 백그라운드 핸들러 진입 시(별도 isolate)
  /// 둘 다에서 호출해야 한다 — 두 isolate는 상태를 공유하지 않는다.
  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings();
    await _plugin.initialize(
      const InitializationSettings(android: androidSettings, iOS: iosSettings),
    );

    final androidImpl = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (androidImpl != null) {
      for (final spec in _specs.values) {
        await androidImpl.createNotificationChannel(spec.channel);
      }
      // Android 13+(targetSdk 33+)는 알림 표시 자체에 런타임 권한이 필요하다 —
      // 이게 없으면 서버/FCM은 전부 성공으로 나오는데 폰엔 아무것도 안 뜨는,
      // 지금까지 겪던 증상과 똑같은 실패가 조용히 발생한다.
      await androidImpl.requestNotificationsPermission();
    }
  }

  static ({AndroidNotificationChannel channel, Priority priority}) _specFor(
    String? severity,
  ) =>
      _specs[severity] ?? _specs['low']!;

  /// data-only FCM 메시지(RemoteMessage.data에 title/body/severity)를 받아
  /// severity에 맞는 채널로 로컬 알림을 띄운다.
  static Future<void> show(RemoteMessage message) async {
    await init();

    final data = message.data;
    final title = (data['title'] as String?) ?? '';
    final body = (data['body'] as String?) ?? '';
    final spec = _specFor(data['severity'] as String?);

    await _plugin.show(
      message.hashCode,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          spec.channel.id,
          spec.channel.name,
          channelDescription: spec.channel.description,
          importance: spec.channel.importance,
          priority: spec.priority,
          enableVibration: spec.channel.enableVibration,
          vibrationPattern: spec.channel.vibrationPattern,
        ),
        iOS: const DarwinNotificationDetails(),
      ),
    );
  }
}
