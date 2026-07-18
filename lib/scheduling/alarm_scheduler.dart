import 'dart:convert';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/lobby/services/lobby_api_service.dart';

/// Exact one-shot alarms for the build scheduler's login/logout/buildRun
/// blocks, so they fire the device API even when the app is backgrounded or
/// killed. Each block gets its own AlarmManager alarm (no minimum-interval
/// floor like WorkManager), running the block's action in a background
/// isolate via [_executeScheduledBlockAlarm].
class AlarmScheduler {
  AlarmScheduler._();

  static const String _scheduledIdsPrefKey = 'scheduled_alarm_ids';
  static final RegExp _timePattern = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$');

  static Future<bool> initialize() => AndroidAlarmManager.initialize();

  /// Cancels every alarm this app previously armed, then re-arms one alarm
  /// per still-future block across all dates in [schedules]. Call this
  /// whenever the schedule changes (and once at app startup) so alarms stay
  /// in sync with what's actually saved.
  static Future<void> rescheduleAll(
    Map<String, List<Map<String, dynamic>>> schedules,
  ) async {
    final prefs = await SharedPreferences.getInstance();

    final previousIds = prefs.getStringList(_scheduledIdsPrefKey) ?? [];
    for (final idStr in previousIds) {
      final id = int.tryParse(idStr);
      if (id != null) {
        await AndroidAlarmManager.cancel(id);
      }
    }

    final now = DateTime.now();
    final nextIds = <String>[];

    for (final entry in schedules.entries) {
      final date = _parseDateKey(entry.key);
      if (date == null) continue;

      for (final block in entry.value) {
        final deviceIp = block['deviceIp']?.toString() ?? '';
        final type = block['type']?.toString() ?? '';
        final time = block['time']?.toString() ?? '';
        if (deviceIp.isEmpty || type.isEmpty || !_timePattern.hasMatch(time)) {
          continue;
        }

        final parts = time.split(':');
        final fireAt = DateTime(
          date.year,
          date.month,
          date.day,
          int.parse(parts[0]),
          int.parse(parts[1]),
        );
        // No catch-up firing for times already passed.
        if (!fireAt.isAfter(now)) continue;

        final account = block['account']?.toString();
        final id = _alarmId(entry.key, deviceIp, type, account, time);

        final ok = await AndroidAlarmManager.oneShotAt(
          fireAt,
          id,
          _executeScheduledBlockAlarm,
          exact: true,
          wakeup: true,
          allowWhileIdle: true,
          rescheduleOnReboot: true,
          params: {
            'deviceIp': deviceIp,
            'type': type,
            if (account != null) 'account': account,
            if (block['cycles'] != null) 'cycles': block['cycles'],
          },
        );
        if (ok) nextIds.add('$id');
      }
    }

    await prefs.setStringList(_scheduledIdsPrefKey, nextIds);
  }

  static int _alarmId(
    String dateKey,
    String deviceIp,
    String type,
    String? account,
    String time,
  ) {
    final key = '$dateKey|$deviceIp|$type|${account ?? ''}|$time';
    return key.hashCode & 0x7fffffff;
  }

  static DateTime? _parseDateKey(String key) {
    final parts = key.split('-');
    if (parts.length != 3) return null;
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final day = int.tryParse(parts[2]);
    if (year == null || month == null || day == null) return null;
    return DateTime(year, month, day);
  }
}

/// Runs in the AlarmManager background isolate — no access to the running
/// app's state, so account/build-mapping data is reloaded from
/// SharedPreferences here rather than passed in from the UI.
@pragma('vm:entry-point')
void _executeScheduledBlockAlarm(int id, Map<String, dynamic> params) async {
  final deviceIp = params['deviceIp']?.toString() ?? '';
  final type = params['type']?.toString() ?? '';
  final account = params['account']?.toString();
  final rawCycles = params['cycles'];
  final cycles = rawCycles is int ? rawCycles : int.tryParse('$rawCycles');

  if (deviceIp.isEmpty) return;

  final api = LobbyApiService(ip: deviceIp);

  try {
    switch (type) {
      case 'login':
        if (account == null || account.isEmpty) return;
        final macros = await api.fetchMacros();
        final match = macros.firstWhere(
          (m) => m['id']?.toString() == account,
          orElse: () => const {},
        );
        final accountId = match['id']?.toString();
        final pw = match['pw']?.toString();
        if (accountId == null || pw == null) return;
        await api.login(accountId, pw);
        break;
      case 'logout':
        await api.logout();
        break;
      case 'buildRun':
        if (account == null || account.isEmpty) return;
        final buildName = await _loadMappedBuild(account);
        if (buildName == null || buildName.isEmpty) return;
        final now = DateTime.now();
        await api.setCycle(cycles ?? 1);
        await api.start(buildName, now.hour, now.minute);
        break;
    }
  } catch (_) {}
}

Future<String?> _loadMappedBuild(String account) async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString('build_mapping');
  if (raw == null || raw.isEmpty) return null;

  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      final value = decoded[account];
      if (value is String) return value;
      if (value is Map) return value['build']?.toString();
    }
  } catch (_) {}
  return null;
}
