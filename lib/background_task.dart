import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter/material.dart';

Map<String, double> parseMetrics(String data) {
  final metrics = <String, double>{};
  final regex = RegExp(r'(liecheck|viol|shape|exception):\s*([0-9.]+)');
  for (final match in regex.allMatches(data)) {
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
      final response = await http.get(Uri.parse('http://$ip/status/')).timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final jsonResp = json.decode(response.body);
        if (jsonResp['status'] == 200 && jsonResp['data'] is String) {
          final metrics = parseMetrics(jsonResp['data']);
          if (isRedStatus(metrics)) {
            hasRed = true;
            break;
          }
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
