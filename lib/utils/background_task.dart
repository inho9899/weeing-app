import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/material.dart';

import 'package:weeing_app/gateway/gateway.dart';

/// 통일 봉투의 resp(Map 또는 "k:v,k:v" 문자열) → 메트릭 Map.
Map<String, double> parseMetrics(dynamic data) {
  final metrics = <String, double>{};
  const keys = ['liecheck', 'viol', 'shape', 'exception'];

  if (data is Map) {
    for (final key in keys) {
      final v = data[key];
      if (v is num) {
        metrics[key] = v.toDouble();
      } else if (v != null) {
        final p = double.tryParse('$v');
        if (p != null) metrics[key] = p;
      }
    }
    return metrics;
  }

  final regex = RegExp(r'(liecheck|viol|shape|exception):\s*([0-9.]+)');
  for (final match in regex.allMatches(data.toString())) {
    metrics[match.group(1)!] = double.tryParse(match.group(2)!) ?? 0.0;
  }
  return metrics;
}

bool isRedStatus(Map<String, double> metrics) {
  return metrics.values.any((v) => v >= 0.8);
}

Future<void> runBackgroundDeviceCheck() async {
  print('[BG] device check start');
  final prefs = await SharedPreferences.getInstance();
  final deviceList = prefs.getStringList('device_list') ?? [];
  bool hasRed = false;

  for (final ip in deviceList) {
    try {
      final response = await Gateway.call(ip, 'statusChecker/status/get', method: 'GET')
          .timeout(const Duration(seconds: 5));
      final resp = Gateway.unwrap(response); // 200 아니면 null
      if (resp != null) {
        final metrics = parseMetrics(resp);
        if (isRedStatus(metrics)) {
          hasRed = true;
          break;
        }
      }
    } catch (e) {
      print('[BG] error for $ip: $e');
    }
  }

  if (hasRed) {
    final notifications = FlutterLocalNotificationsPlugin();
    const androidDetails = AndroidNotificationDetails(
      'alert_channel',
      'Alert Notifications',
      channelDescription: 'Notification for device alert',
      importance: Importance.max,
      priority: Priority.high,
      color: Colors.red,
    );
    const iosDetails = DarwinNotificationDetails();
    const details = NotificationDetails(android: androidDetails, iOS: iosDetails);
    await notifications.initialize(const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(),
    ));
    await notifications.show(
      2,
      '기기 이상 감지 (백그라운드)',
      '빨간 상태의 기기가 있습니다.',
      details,
    );
    print('[BG] RED detected, notification sent');
  } else {
    print('[BG] No RED detected');
  }
}
