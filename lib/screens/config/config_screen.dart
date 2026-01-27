import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'package:weeing_app/utils/background_task.dart';
import 'models/device_info.dart';
import 'widgets/device_row.dart';
import 'widgets/add_ip_dialog.dart';

const String backgroundTaskKey = 'device_status_check';

class ConfigScreen extends StatefulWidget {
  final String fcmToken;
  const ConfigScreen({super.key, required this.fcmToken});

  @override
  State<ConfigScreen> createState() => _ConfigScreenState();
}

class _ConfigScreenState extends State<ConfigScreen> {
  final List<DeviceInfo> _devices = [];

  Timer? _pollTimer;
  bool _hasRedPushSent = false;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  // IPv4 형식 검사: xxx.xxx.xxx.xxx 또는 xxx.xxx.xxx.xxx:포트
  final RegExp _ipRegex = RegExp(
    r'^([0-9]{1,3}\.){3}[0-9]{1,3}(:[0-9]{1,5})?$',
  );

  @override
  void initState() {
    super.initState();
    _initNotifications();
    _loadDevices();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      _refreshAllStatuses();
    });
  }

  Future<void> _initNotifications() async {
    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings();
    const initSettings =
        InitializationSettings(android: androidSettings, iOS: iosSettings);
    await _localNotifications.initialize(initSettings);
  }

  Future<void> _loadDevices() async {
    final prefs = await SharedPreferences.getInstance();
    final deviceList = prefs.getStringList('device_list') ?? [];
    setState(() {
      _devices.clear();
      _devices.addAll(deviceList.map((ip) => DeviceInfo(ip: ip)));
    });
    _refreshAllStatuses();
  }

  Future<void> _saveDevices() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        'device_list', _devices.map((d) => d.ip).toList());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshAllStatuses() async {
    for (int i = 0; i < _devices.length; i++) {
      _checkStatusForIndex(i);
    }
  }

  void _checkAnyRedAndAlert() {
    final hasRed = _devices.any((d) => d.enabled && d.color == Colors.red);
    if (!hasRed) {
      _hasRedPushSent = false;
    }
  }

  Future<void> _checkStatusForIndex(int index) async {
    if (index < 0 || index >= _devices.length) return;

    final device = _devices[index];
    final host = device.ip.split(':')[0];
    final uri = Uri.parse('http://$host:8001/status/');

    try {
      final response = await http.get(uri).timeout(const Duration(seconds: 2));

      bool isOk = false;
      bool isRed = false;

      try {
        final decoded = jsonDecode(response.body);
        final bodyStatus = decoded['status'];
        isOk = bodyStatus == 200;

        final data = decoded['data'];
        if (data is String) {
          final lower = data.toLowerCase();
          double parseMetric(String key) {
            final regex = RegExp('$key\\s*:\\s*([0-9.]+)');
            final match = regex.firstMatch(lower);
            if (match != null) {
              return double.tryParse(match.group(1) ?? '') ?? 0.0;
            }
            return 0.0;
          }

          final liecheck = parseMetric('liecheck');
          final viol = parseMetric('viol');
          final shape = parseMetric('shape');
          final exception = parseMetric('exception');

          const threshold = 0.8;
          if (liecheck >= threshold ||
              viol >= threshold ||
              shape >= threshold ||
              exception >= threshold) {
            isRed = true;
          }
        }
      } catch (_) {}

      if (!mounted) return;

      setState(() {
        if (!isOk) {
          _devices[index] = device.copyWith(
            enabled: false,
            color: Colors.grey,
          );
        } else if (isRed) {
          _devices[index] = device.copyWith(
            enabled: true,
            color: Colors.red,
          );
        } else {
          _devices[index] = device.copyWith(
            enabled: true,
            color: Colors.green,
          );
        }
      });

      _checkAnyRedAndAlert();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _devices[index] = device.copyWith(
          enabled: false,
          color: Colors.grey,
        );
      });
      _checkAnyRedAndAlert();
    }
  }

  Future<void> _handleAddIp() async {
    final newIp = await showAddIpDialog(context, _ipRegex);
    if (newIp == null) return;

    setState(() {
      _devices.add(DeviceInfo(ip: newIp));
    });
    await _saveDevices();
    await _checkStatusForIndex(_devices.length - 1);

    // 디바이스에 FCM 등록 요청
    try {
      final url = Uri.parse(
          'http://$newIp/status/addFCM?token=${Uri.encodeComponent(widget.fcmToken)}');
      await http
          .post(
            url,
            headers: {'Content-Type': 'application/x-www-form-urlencoded'},
          )
          .timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  Future<void> _confirmDeleteDevice(int index) async {
    if (index < 0 || index >= _devices.length) return;
    final targetIp = _devices[index].ip;

    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('삭제 확인'),
          content: Text('정말 "$targetIp" 을(를) 지우시겠습니까?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('취소'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('삭제'),
            ),
          ],
        );
      },
    );

    if (result == true) {
      setState(() {
        _devices.removeAt(index);
      });
      await _saveDevices();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF3F3F5),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '원격 기기',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),

              // 카드 영역
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey.shade400),
                ),
                child: Column(
                  children: [
                    for (int i = 0; i < _devices.length; i++) ...[
                      DeviceRow(
                        ip: _devices[i].ip,
                        color: _devices[i].color,
                        enabled: _devices[i].enabled,
                        onDelete: () => _confirmDeleteDevice(i),
                      ),
                      if (i != _devices.length - 1)
                        const Divider(height: 1, thickness: 0.5),
                    ],
                  ],
                ),
              ),

              const SizedBox(height: 32),

              // 기기 추가 버튼
              GestureDetector(
                onTap: _handleAddIp,
                child: Container(
                  width: double.infinity,
                  height: 80,
                  decoration: BoxDecoration(
                    color: const Color(0xFFE2E2E2),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: Colors.grey.shade500,
                      style: BorderStyle.solid,
                    ),
                  ),
                  child: const Center(
                    child: Icon(
                      Icons.add,
                      size: 32,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 32),
              const Divider(),
              const SizedBox(height: 16),
              const Text('FCM 토큰:',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SelectableText('', style: TextStyle(fontSize: 12)),
              const SizedBox(height: 16),
              const Divider(),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text('FCM 수신 로그:',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              const SizedBox(height: 8),
              const Expanded(
                child: SingleChildScrollView(
                  reverse: true,
                  child: Text('', style: TextStyle(fontSize: 12)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
