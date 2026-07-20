import 'dart:convert';
import 'package:flutter/material.dart';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'package:weeing_app/gateway/gateway.dart';
import 'models/device_info.dart';
import 'widgets/device_row.dart';
import 'widgets/add_ip_dialog.dart';
import 'widgets/rename_device_dialog.dart';
import 'widgets/build_mapping_dialog.dart';
import 'widgets/build_scheduler_dialog.dart';

const String backgroundTaskKey = 'device_status_check';

class ConfigScreen extends StatefulWidget {
  final String fcmToken;
  const ConfigScreen({super.key, required this.fcmToken});

  @override
  State<ConfigScreen> createState() => _ConfigScreenState();
}

class _ConfigScreenState extends State<ConfigScreen> {
  final List<DeviceInfo> _devices = [];
  Map<String, String> _buildMappings = {};
  Map<String, List<Map<String, dynamic>>> _buildSchedules = {};

  Timer? _pollTimer;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  // IPv4 형식 검사: xxx.xxx.xxx.xxx (port는 cloudflare가 서비스명으로 정하므로 안 받음)
  final RegExp _ipRegex = RegExp(
    r'^([0-9]{1,3}\.){3}[0-9]{1,3}$',
  );

  @override
  void initState() {
    super.initState();
    _initNotifications();
    _loadDevices();
    _bootstrapBuildMappings();
    _bootstrapSchedules();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      _refreshAllStatuses();
    });
  }

  // 빌드 스케줄은 이제 proxy 에 상주하는 스케줄러(cloudfare/scheduler.py)가
  // 실행 주체다. 서버가 source of truth 이므로 우선 서버에서 조회하고,
  // 오프라인 등으로 실패했을 때만 로컬 캐시(SharedPreferences)로 폴백한다.
  Future<void> _bootstrapSchedules() async {
    final remote = await Gateway.fetchSchedules();
    if (remote != null) {
      if (!mounted) return;
      setState(() {
        _buildSchedules = remote;
      });
      await _saveBuildSchedulesLocalCache();
      return;
    }
    await _loadBuildSchedules();
  }

  Future<void> _bootstrapBuildMappings() async {
    final remote = await Gateway.fetchBuildMapping();
    if (remote != null) {
      if (!mounted) return;
      setState(() {
        _buildMappings = remote;
      });
      await _saveBuildMappingsLocalCache();
      return;
    }
    await _loadBuildMappings();
  }

  void _warnServerSaveFailed(String what) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '$what 서버 저장에 실패했습니다. 이 상태로는 예약된 실행에 반영되지 않습니다. '
          '네트워크 확인 후 다시 저장해주세요.',
        ),
        duration: const Duration(seconds: 6),
      ),
    );
  }

  void _warnServerFetchFailed(String what) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '$what 서버 조회에 실패해 기기에 저장된 이전 값을 보여줍니다. '
          '실제 프록시 스케줄과 다를 수 있으니 네트워크 확인 후 다시 열어주세요.',
        ),
        duration: const Duration(seconds: 6),
      ),
    );
  }

  Future<void> _initNotifications() async {
    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const iosSettings = DarwinInitializationSettings();
    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );
    await _localNotifications.initialize(initSettings);

    // FCM은 앱이 포그라운드일 때 시스템 알림 배너를 자동으로 띄워주지 않는다
    // (백그라운드/종료 상태에서만 OS가 대신 표시함). 그래서 포그라운드 수신은
    // 직접 받아서 로컬 알림으로 띄워줘야 한다.
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      final notification = message.notification;
      if (notification == null) return;
      _localNotifications.show(
        notification.hashCode,
        notification.title,
        notification.body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'alert_channel',
            'Alert Notifications',
            channelDescription: 'Notification for device alert',
            importance: Importance.max,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),
        ),
      );
    });
  }

  Future<void> _loadDevices() async {
    final prefs = await SharedPreferences.getInstance();
    final loaded = <DeviceInfo>[];

    final raw = prefs.getString('device_list_v2');
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final entry in decoded) {
            if (entry is! Map) continue;
            final ip = entry['ip']?.toString();
            if (ip == null || ip.isEmpty) continue;
            loaded.add(DeviceInfo(
              ip: ip,
              name: entry['name']?.toString(),
              deviceId: entry['deviceId']?.toString(),
            ));
          }
        }
      } catch (_) {}
    } else {
      // 구버전 저장 포맷(ip 문자열 리스트) 마이그레이션: 명칭은 ip로 초기화.
      final legacyList = prefs.getStringList('device_list') ?? [];
      loaded.addAll(legacyList.map((ip) => DeviceInfo(ip: ip)));
    }

    setState(() {
      _devices.clear();
      _devices.addAll(loaded);
    });
    await _saveDevices();
    _refreshAllStatuses();
  }

  Future<void> _loadBuildMappings() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('build_mapping');
    if (raw == null || raw.isEmpty) return;

    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final nextMappings = <String, String>{};
        for (final entry in decoded.entries) {
          final value = entry.value;
          if (value is String) {
            nextMappings[entry.key.toString()] = value;
          } else if (value is Map) {
            final build = value['build']?.toString();
            if (build != null && build.isNotEmpty) {
              nextMappings[entry.key.toString()] = build;
            }
          } else if (value != null) {
            final build = value.toString();
            if (build.isNotEmpty) {
              nextMappings[entry.key.toString()] = build;
            }
          }
        }
        if (!mounted) return;
        setState(() {
          _buildMappings = nextMappings;
        });
      }
    } catch (_) {}
  }

  Future<void> _saveDevices() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'device_list_v2',
      jsonEncode(_devices
          .map((d) => {'ip': d.ip, 'name': d.name, 'deviceId': d.deviceId})
          .toList()),
    );
    // 구버전 키는 더 이상 쓰지 않지만, 남아있으면 다음 실행 때 다시
    // 마이그레이션 분기를 타지 않도록 지운다.
    await prefs.remove('device_list');
  }

  Future<void> _saveBuildMappingsLocalCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('build_mapping', jsonEncode(_buildMappings));
  }

  Future<void> _loadBuildSchedules() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('build_scheduler');
    if (raw == null || raw.isEmpty) return;

    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final nextSchedules = <String, List<Map<String, dynamic>>>{};
        for (final entry in decoded.entries) {
          final dayKey = entry.key.toString();
          final value = entry.value;
          if (value is List) {
            final blocks = value
                .whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e))
                .toList();
            if (blocks.isNotEmpty) {
              nextSchedules[dayKey] = blocks;
            }
          }
        }
        if (!mounted) return;
        setState(() {
          _buildSchedules = nextSchedules;
        });
      }
    } catch (_) {}
  }

  Future<void> _saveBuildSchedulesLocalCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('build_scheduler', jsonEncode(_buildSchedules));
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

  Future<void> _checkStatusForIndex(int index) async {
    if (index < 0 || index >= _devices.length) return;

    final device = _devices[index];

    try {
      final response = await Gateway.call(
        device.ip,
        'statusChecker/status/get',
        method: 'GET',
      ).timeout(const Duration(seconds: 2));

      // 통일 봉투: 200 이면 resp 존재(=기기 응답 OK), 아니면 null(회색).
      final resp = Gateway.unwrap(response);
      bool isOk = resp != null;
      bool isRed = false;

      if (resp != null) {
        try {
          // resp 가 Map({liecheck:0.1,..}) 이든 "k:v,k:v" 문자열이든 지원.
          double metric(String key) {
            if (resp is Map) {
              final v = resp[key];
              if (v is num) return v.toDouble();
              return double.tryParse('${v ?? ''}') ?? 0.0;
            }
            final regex = RegExp('$key\\s*:\\s*([0-9.]+)');
            final m = regex.firstMatch(resp.toString().toLowerCase());
            return m != null ? (double.tryParse(m.group(1) ?? '') ?? 0.0) : 0.0;
          }

          const threshold = 0.8;
          if (metric('liecheck') >= threshold ||
              metric('viol') >= threshold ||
              metric('shape') >= threshold ||
              metric('exception') >= threshold) {
            isRed = true;
          }
        } catch (_) {}
      }

      if (!mounted) return;

      setState(() {
        if (!isOk) {
          _devices[index] = device.copyWith(enabled: false, color: Colors.grey);
        } else if (isRed) {
          _devices[index] = device.copyWith(enabled: true, color: Colors.red);
        } else {
          _devices[index] = device.copyWith(enabled: true, color: Colors.green);
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _devices[index] = device.copyWith(enabled: false, color: Colors.grey);
      });
    }
  }

  Future<void> _handleAddIp() async {
    final result = await showAddIpDialog(context, _ipRegex);
    if (result == null) return;
    final newIp = result.ip;
    final newName = result.name;

    // 핸드셰이크 먼저: cloudflare가 이 ip의 PC(alarmHandler)에 직접 접속해서
    // 별칭을 저장시키고 device_id→명칭 매핑까지 등록한다. 이게 성공해야만
    // 이 PC가 실제로 살아있고 프록시로 도달 가능하다는 뜻이므로, 실패하면
    // 로컬 목록에 추가하지 않는다.
    final deviceId = await Gateway.registerDeviceName(
      newIp,
      newName,
      widget.fcmToken,
    );
    if (deviceId == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'PC와 연결을 확인하지 못했습니다. IP와 PC 전원/네트워크를 확인 후 다시 시도해주세요.',
          ),
          duration: Duration(seconds: 6),
        ),
      );
      return;
    }

    setState(() {
      _devices.add(DeviceInfo(ip: newIp, name: newName, deviceId: deviceId));
    });
    await _saveDevices();
    await _checkStatusForIndex(_devices.length - 1);

    // FCM 발송 대상 등록은 별도 호출이 필요 없다 — cloudflare는 device_names.json에
    // PC를 하나라도 등록한 토큰이면 자동으로 발송 대상으로 취급한다(위 handshake로 이미 등록됨).
  }

  Future<void> _openBuildMappingScreen() async {
    final result = await Navigator.of(context).push<Map<String, String>>(
      MaterialPageRoute(
        builder: (_) => BuildMappingDialog(
          devices: List<DeviceInfo>.from(_devices),
          initialMappings: _buildMappings,
        ),
      ),
    );

    if (result == null) return;

    if (!mounted) return;
    setState(() {
      _buildMappings = result;
    });
    await _saveBuildMappingsLocalCache();
    final ok = await Gateway.saveBuildMapping(_buildMappings);
    if (!ok) _warnServerSaveFailed('빌드 매핑');
  }

  // 스케줄 실행 주체는 이제 proxy 쪽 스케줄러다. 다른 세션/기기나 서버에서
  // 직접 바꾼 내용이 있을 수 있으므로, 화면을 열 때마다 로컬 캐시가 아니라
  // proxy 를 다시 조회해 최신 상태로 보여준다.
  Future<void> _openBuildSchedulerScreen() async {
    final remote = await Gateway.fetchSchedules();
    if (remote != null) {
      if (!mounted) return;
      setState(() {
        _buildSchedules = remote;
      });
      await _saveBuildSchedulesLocalCache();
    } else {
      _warnServerFetchFailed('빌드 스케줄');
    }

    if (!mounted) return;

    final result = await Navigator.of(context)
        .push<Map<String, List<Map<String, dynamic>>>>(
          MaterialPageRoute(
            builder: (_) => BuildSchedulerDialog(
              devices: List<DeviceInfo>.from(_devices),
              buildMappings: _buildMappings,
              initialSchedules: _buildSchedules,
            ),
          ),
        );

    if (result == null) return;

    if (!mounted) return;
    setState(() {
      _buildSchedules = result;
    });
    await _saveBuildSchedulesLocalCache();
    final ok = await Gateway.saveSchedules(_buildSchedules);
    if (!ok) _warnServerSaveFailed('빌드 스케줄');
  }

  Future<void> _confirmDeleteDevice(int index) async {
    if (index < 0 || index >= _devices.length) return;
    final targetName = _devices[index].name;

    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('삭제 확인'),
          content: Text('정말 "$targetName" 을(를) 지우시겠습니까?'),
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
      final deviceId = _devices[index].deviceId;
      setState(() {
        _devices.removeAt(index);
      });
      await _saveDevices();

      // cloudflare 쪽 device_id→명칭 매핑도 같이 지운다 (없으면 PC가 죽은 채로
      // 알림에 계속 뜨거나, 이 device_id를 재사용하는 다른 기기와 이름이 꼬일 수 있음).
      // deviceId가 없는 건 구버전 흐름으로 추가된 기기 — cloudflare에 지울 대상이 없다.
      if (deviceId != null) {
        final ok = await Gateway.removeDeviceName(deviceId, widget.fcmToken);
        if (!ok && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                '기기 목록에서는 지웠지만, 서버의 이름 매핑은 정리하지 못했습니다 '
                '(네트워크 확인 후 다시 시도해주세요).',
              ),
              duration: Duration(seconds: 6),
            ),
          );
        }
      }
    }
  }

  Future<void> _handleRenameDevice(int index) async {
    if (index < 0 || index >= _devices.length) return;
    final device = _devices[index];

    if (device.deviceId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            '예전 방식으로 추가된 기기라 이름을 수정할 수 없습니다. '
            '삭제 후 다시 추가해주세요.',
          ),
          duration: Duration(seconds: 6),
        ),
      );
      return;
    }

    final newName = await showRenameDeviceDialog(context, device.name);
    if (newName == null || newName == device.name) return;

    final ok = await Gateway.renameDeviceName(
      device.deviceId!,
      newName,
      widget.fcmToken,
    );
    if (!ok) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('이름 수정에 실패했습니다. 네트워크 확인 후 다시 시도해주세요.'),
          duration: Duration(seconds: 6),
        ),
      );
      return;
    }

    setState(() {
      _devices[index] = device.copyWith(name: newName);
    });
    await _saveDevices();

    // cloudflare 쪽 매핑(진짜 소스)은 이미 갱신됐다. PC가 지금 켜져 있으면
    // 로컬 참고용 캐시(device_info.json)도 같이 맞춰준다 — 꺼져 있어도 위의
    // 서버 갱신은 이미 끝났으니 실패해도 그냥 무시한다(best-effort).
    try {
      await Gateway.call(
        device.ip,
        'alarmHandler/handshake',
        method: 'POST',
        params: {'name': newName},
      ).timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '원격 기기',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF1A1A1C),
        elevation: 0,
        scrolledUnderElevation: 0.5,
        centerTitle: false,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12.0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilledButton.icon(
                  onPressed: _openBuildMappingScreen,
                  icon: const Icon(Icons.tune, size: 18),
                  label: const Text('빌드 매핑'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF3B82F6),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    textStyle: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _openBuildSchedulerScreen,
                  icon: const Icon(Icons.schedule, size: 18),
                  label: const Text('빌드 스케줄러'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF0F766E),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    textStyle: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      backgroundColor: const Color(0xFFF3F3F5),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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
                        name: _devices[i].name,
                        color: _devices[i].color,
                        enabled: _devices[i].enabled,
                        onRename: () => _handleRenameDevice(i),
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
                  child: const Center(child: Icon(Icons.add, size: 32)),
                ),
              ),
              const SizedBox(height: 32),
              const Divider(),
              const SizedBox(height: 16),
              const Text(
                'FCM 토큰:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SelectableText('', style: TextStyle(fontSize: 12)),
              const SizedBox(height: 16),
              const Divider(),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'FCM 수신 로그:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
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
