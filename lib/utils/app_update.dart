import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

/// 앱 자동 업데이트. 프록시(/app/version, /app/download)에서 최신 빌드를 확인해
/// 더 새 빌드가 있으면 물어보고, 받아서 Android 설치 화면을 띄운다.
///
/// 주소는 설정 화면의 게이트웨이 주소와 무관하게 고정이다 — 주소를 잘못 넣어
/// 아무것도 안 되는 상태에서도 업데이트는 받을 수 있어야 한다. 그래서 이 도메인을
/// 바꾸면 그 전에 깔린 앱은 업데이트를 영영 못 찾는다.
///
/// Android 는 스토어 밖 앱의 무음 설치를 막으므로 [설치]는 사용자가 누른다.
/// APK 는 release.py 로 빌드·배포한다.
class AppUpdate {
  AppUpdate._();

  static DateTime? _lastCheck;
  static bool _busy = false;

  /// 설정 화면 하단 표시용 "nongameanbun v.0.1.0". 못 읽으면(Android 아님 등) 빈 문자열.
  static Future<String> versionLabel() async {
    try {
      final name = await const MethodChannel('weeing/app_update')
          .invokeMethod<String>('versionName');
      return 'nongameanbun v.$name';
    } catch (e) {
      debugPrint('AppUpdate: version read failed: $e');
      return '';
    }
  }

  /// 앱 시작·복귀 때 부른다. 10분 안에 다시 불리면 건너뛴다.
  /// 실패(오프라인, 프록시 꺼짐)는 조용히 넘어간다.
  static Future<void> check(BuildContext context) async {
    if (!Platform.isAndroid || _busy) return;
    final now = DateTime.now();
    final last = _lastCheck;
    if (last != null && now.difference(last).inMinutes < 10) return;
    _lastCheck = now;
    _busy = true;
    try {
      final latest = await _fetchLatest();
      if (latest == null) return;
      final current =
          await const MethodChannel(
            'weeing/app_update',
          ).invokeMethod<int>('currentBuild') ??
          0;
      if (latest.build <= current) return;
      if (!context.mounted) return;
      await _prompt(context, latest);
    } catch (e) {
      debugPrint('AppUpdate: check failed: $e');
    } finally {
      _busy = false;
    }
  }

  static Future<({int build, String version, int size})?> _fetchLatest() async {
    final res = await http
        .get(Uri.parse('https://api.nongameanbun.xyz/app/version'))
        .timeout(const Duration(seconds: 5));
    if (res.statusCode != 200) return null;
    final resp = (jsonDecode(res.body) as Map)['resp'];
    if (resp is! Map) return null; // 아직 배포된 빌드 없음
    return (
      build: (resp['build'] as num).toInt(),
      version: resp['version']?.toString() ?? '',
      size: (resp['size'] as num?)?.toInt() ?? 0,
    );
  }

  static Future<void> _prompt(
    BuildContext context,
    ({int build, String version, int size}) latest,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('업데이트'),
        content: const Text('새 버전이 있습니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('나중에'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('업데이트'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;

    final progress = ValueNotifier<double?>(null);
    final error = ValueNotifier<String?>(null);
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => _ProgressDialog(progress: progress, error: error),
      ),
    );

    try {
      final path = await _download(latest.build, latest.size, progress);
      final result = await const MethodChannel(
        'weeing/app_update',
      ).invokeMethod<String>('install', {'path': path});
      if (result == 'permission') {
        error.value = '"출처를 알 수 없는 앱 설치"를 허용한 뒤 다시 업데이트를 눌러주세요.';
        _lastCheck = null; // 돌아오면 바로 다시 묻도록
        return;
      }
      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    } catch (e) {
      debugPrint('AppUpdate: update failed: $e');
      error.value = '업데이트를 받지 못했습니다.\n$e';
      _lastCheck = null;
    }
  }

  static Future<String> _download(
    int build,
    int size,
    ValueNotifier<double?> progress,
  ) async {
    final dir = await const MethodChannel(
      'weeing/app_update',
    ).invokeMethod<String>('updateDir');
    final file = File('$dir/weeing-$build.apk');
    final tmp = File('${file.path}.part');

    final client = http.Client();
    try {
      final res = await client
          .send(
            http.Request(
              'GET',
              Uri.parse('https://api.nongameanbun.xyz/app/download?v=$build'),
            ),
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        throw HttpException('download HTTP ${res.statusCode}');
      }
      final total = res.contentLength ?? size;
      final sink = tmp.openWrite();
      var received = 0;
      try {
        await for (final chunk in res.stream.timeout(
          const Duration(seconds: 30),
        )) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) progress.value = received / total;
        }
      } finally {
        await sink.close();
      }
      // 프록시 APK 는 하나로 고정이라 배포 틈에 version.json 과 다른(더 새) 빌드가 올 수
      // 있다 — 그래서 version.json 의 size 가 아니라 이 응답의 길이로 확인한다.
      final expected = res.contentLength;
      if (expected != null && received != expected) {
        throw HttpException('download incomplete ($received / $expected bytes)');
      }
      if (await file.exists()) await file.delete();
      await tmp.rename(file.path);
      return file.path;
    } finally {
      client.close();
    }
  }
}

class _ProgressDialog extends StatelessWidget {
  final ValueNotifier<double?> progress;
  final ValueNotifier<String?> error;

  const _ProgressDialog({required this.progress, required this.error});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: error,
      builder: (context, message, _) {
        if (message != null) {
          return AlertDialog(
            title: const Text('업데이트'),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('닫기'),
              ),
            ],
          );
        }
        return AlertDialog(
          title: const Text('업데이트 받는 중'),
          content: ValueListenableBuilder<double?>(
            valueListenable: progress,
            builder: (context, value, _) =>
                LinearProgressIndicator(value: value),
          ),
        );
      },
    );
  }
}
