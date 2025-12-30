import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'background_task.dart';
import 'lobby_screen.dart';
import 'dart:io';

const String backgroundTaskKey = 'device_status_check';

class ConfigScreen extends StatefulWidget {
  final String fcmToken;
  const ConfigScreen({super.key, required this.fcmToken});

  @override
  State<ConfigScreen> createState() => _ConfigScreenState();
}

class _ConfigScreenState extends State<ConfigScreen> {
  final List<_DeviceInfo> _devices = [];

  Timer? _pollTimer;
  bool _hasRedPushSent = false;
  final FlutterLocalNotificationsPlugin _localNotifications = FlutterLocalNotificationsPlugin();

  // IPv4 형식 검사: xxx.xxx.xxx.xxx 또는 xxx.xxx.xxx.xxx:포트 (숫자 패턴만 확인)
  final RegExp _ipRegex = RegExp(
    r'^([0-9]{1,3}\.){3}[0-9]{1,3}(:[0-9]{1,5})?$',
  );

  @override
  void initState() {
    super.initState();
    _initNotifications();
    _loadDevices();
    // print('[ConfigScreen] initState - 초기 상태 체크 시작');
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      // print('[ConfigScreen] Timer tick #${timer.tick} - 전체 상태 재체크');
      _refreshAllStatuses();
    });
  }

  Future<void> _initNotifications() async {
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings();
    const initSettings = InitializationSettings(android: androidSettings, iOS: iosSettings);
    await _localNotifications.initialize(initSettings);
  }

  Future<void> _loadDevices() async {
    final prefs = await SharedPreferences.getInstance();
    final deviceList = prefs.getStringList('device_list') ?? [];
    setState(() {
      _devices.clear();
      _devices.addAll(deviceList.map((ip) => _DeviceInfo(ip: ip)));
    });
    _refreshAllStatuses();
  }

  Future<void> _saveDevices() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('device_list', _devices.map((d) => d.ip).toList());
  }

  @override
  void dispose() {
    print('[ConfigScreen] dispose - 타이머 정리');
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshAllStatuses() async {
    // print('[ConfigScreen] _refreshAllStatuses - 디바이스 개수: ${_devices.length}');
    for (int i = 0; i < _devices.length; i++) {
      _checkStatusForIndex(i);
    }
  }

  void _checkAnyRedAndAlert() {
    // foreground 경고창 완전 제거
    // background notification만 남김 (필요시)
    // 기존 showDialog 및 _hasRedAlertShown 관련 코드 삭제
    final hasRed = _devices.any((d) => d.enabled && d.color == Colors.red);
    // 앱이 켜져 있을 때 푸시 알림은 더이상 띄우지 않음
    // if (hasRed && !_hasRedPushSent) {
    //   _hasRedPushSent = true;
    //   _localNotifications.show(
    //     1,
    //     '기기 이상 감지',
    //     '빨간 상태의 기기가 있습니다.',
    //     const NotificationDetails(
    //       android: AndroidNotificationDetails(
    //         'alert_channel',
    //         'Alert Notifications',
    //         channelDescription: 'Notification for device alert',
    //         importance: Importance.max,
    //         priority: Priority.high,
    //         color: Colors.red,
    //       ),
    //       iOS: DarwinNotificationDetails(),
    //     ),
    //   );
    // }
    if (!hasRed) {
      _hasRedPushSent = false;
    }
  }

  Future<void> _checkStatusForIndex(int index) async {
    if (index < 0 || index >= _devices.length) {
      // print('[ConfigScreen] _checkStatusForIndex - 잘못된 index: $index');
      return;
    }

    final device = _devices[index];
    final host = device.ip.split(':')[0];
    final uri = Uri.parse('http://$host:8001/status/');

    // print('[ConfigScreen] [${device.ip}] 상태 체크 시작 - URL: $uri');

    try {
      final response = await http.get(uri).timeout(const Duration(seconds: 2));
      // print('[ConfigScreen] [${device.ip}] HTTP status: ${response.statusCode}');
      // print('[ConfigScreen] [${device.ip}] raw body: ${response.body}');

      bool isOk = false;
      bool isRed = false;

      try {
        final decoded = jsonDecode(response.body);
        // print('[ConfigScreen] [${device.ip}] decoded body: $decoded');
        final bodyStatus = decoded['status'];
        isOk = bodyStatus == 200;
        // print('[ConfigScreen] [${device.ip}] body.status: $bodyStatus, isOk: $isOk');

        final data = decoded['data'];
        if (data is String) {
          // 예: "liecheck: 0.0, viol: 0.0, shape: 0.0, elbo: 0.0, exception: 0.0, ..."
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

          // print('[ConfigScreen] [${device.ip}] metrics - liecheck: $liecheck, viol: $viol, shape: $shape, exception: $exception');

          const threshold = 0.8;
          if (liecheck >= threshold ||
              viol >= threshold ||
              shape >= threshold ||
              exception >= threshold) {
            isRed = true;
          }
        }
      } catch (e) {
        // print('[ConfigScreen] [${device.ip}] JSON decode/metrics 파싱 실패: $e');
      }

      if (!mounted) {
        // print('[ConfigScreen] 위젯 unmounted - setState 생략');
        return;
      }

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
    } catch (e) {
      // print('[ConfigScreen] [${device.ip}] 상태 체크 실패: $e');
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

  Future<void> _showAddIpDialog() async {
    final controller = TextEditingController();
    String? errorText;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              title: const Text('IP 주소 추가'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: controller,
                    decoration: InputDecoration(
                      labelText: 'IP 주소',
                      hintText: '예: 192.168.0.1 또는 192.168.0.1:8000',
                      errorText: errorText,
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    // print('[ConfigScreen] IP 추가 취소');
                    Navigator.of(context).pop();
                  },
                  child: const Text('취소'),
                ),
                TextButton(
                  onPressed: () async {
                    final text = controller.text.trim();
                    // print('[ConfigScreen] IP 입력 값: "$text"');

                    if (!_ipRegex.hasMatch(text)) {
                      // print('[ConfigScreen] IP 형식 오류: $text');
                      setStateDialog(() {
                        errorText = '올바른 IP 형식(xxx.xxx.xxx.xxx)으로 다시 입력하세요.';
                      });
                      return;
                    }

                    // print('[ConfigScreen] IP 형식 OK, 리스트에 추가 시도: $text');
                    Navigator.of(context).pop();

                    setState(() {
                      _devices.add(_DeviceInfo(ip: text));
                    });
                    await _saveDevices();
                    // print('[ConfigScreen] 새 디바이스 추가 완료. 총 개수: ${_devices.length}');
                    await _checkStatusForIndex(_devices.length - 1);

                    // 디바이스에 FCM 등록 요청 (token을 query로 전달)
                    try {
                      final url = Uri.parse('http://$text/status/addFCM?token=${Uri.encodeComponent(widget.fcmToken)}');
                      final response = await http.post(
                        url,
                        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
                      ).timeout(const Duration(seconds: 5));
                      print('[ConfigScreen] addFCM 요청 결과: ${response.statusCode} ${response.body}');
                    } catch (e) {
                      print('[ConfigScreen] addFCM 요청 실패: $e');
                    }
                  },
                  child: const Text('확인'),
                ),
              ],
            );
          },
        );
      },
    );
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
      // print('[ConfigScreen] 디바이스 삭제: $targetIp, 남은 개수: ${_devices.length}');
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
                      _DeviceRow(
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
                onTap: _showAddIpDialog,
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
              const Text('FCM 토큰:', style: TextStyle(fontWeight: FontWeight.bold)),
              SelectableText('', style: const TextStyle(fontSize: 12)),
              const SizedBox(height: 16),
              const Divider(),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text('FCM 수신 로그:', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: SingleChildScrollView(
                  reverse: true,
                  child: Text('', style: const TextStyle(fontSize: 12)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DeviceInfo {
  final String ip;
  final Color color;
  final bool enabled;

  const _DeviceInfo({
    required this.ip,
    this.color = Colors.grey,
    this.enabled = false,
  });

  _DeviceInfo copyWith({
    String? ip,
    Color? color,
    bool? enabled,
  }) {
    return _DeviceInfo(
      ip: ip ?? this.ip,
      color: color ?? this.color,
      enabled: enabled ?? this.enabled,
    );
  }
}

class _DeviceRow extends StatelessWidget {
  final String ip;
  final Color color;
  final bool enabled;
  final VoidCallback? onDelete;

  const _DeviceRow({
    required this.ip,
    required this.color,
    required this.enabled,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final textStyle = TextStyle(
      fontSize: 16,
      color: enabled ? color : Colors.grey,
      fontWeight: enabled ? FontWeight.w500 : FontWeight.w400,
    );

    return InkWell(
      onTap: enabled
          ? () {
              final basePath = 'http://$ip/';
              print('[ConfigScreen] Row tapped - navigate to LobbyScreen with basePath: $basePath');
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => LobbyScreen(basePath: basePath),
                ),
              );
            }
          : null, // 비활성(회색)일 때 터치 무시
      child: Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            Icon(
              Icons.desktop_windows,
              size: 24,
              color: enabled ? Colors.black87 : Colors.grey,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(ip, style: textStyle),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '삭제',
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}
