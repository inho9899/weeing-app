import 'dart:convert';
import 'package:flutter/material.dart';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'package:weeing_app/gateway/gateway.dart';
import 'models/device_info.dart';
import 'widgets/device_row.dart';
import 'widgets/add_ip_dialog.dart';
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

  // IPv4 형식 검사: xxx.xxx.xxx.xxx 또는 xxx.xxx.xxx.xxx:포트
  final RegExp _ipRegex = RegExp(
    r'^([0-9]{1,3}\.){3}[0-9]{1,3}(:[0-9]{1,5})?$',
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
    await prefs.setStringList(
      'device_list',
      _devices.map((d) => d.ip).toList(),
    );
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
    final newIp = await showAddIpDialog(context, _ipRegex);
    if (newIp == null) return;

    setState(() {
      _devices.add(DeviceInfo(ip: newIp));
    });
    await _saveDevices();
    await _checkStatusForIndex(_devices.length - 1);

    // 디바이스에 FCM 등록 요청
    try {
      await Gateway.call(
        newIp,
        'subaction/status/addFCM',
        method: 'POST',
        params: {'token': widget.fcmToken},
      ).timeout(const Duration(seconds: 5));
    } catch (_) {}
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
