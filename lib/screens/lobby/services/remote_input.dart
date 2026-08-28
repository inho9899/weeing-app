import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'package:weeing_app/gateway/gateway.dart';

/// 원격 입력 전송을 한 곳으로 모은 서비스.
///
/// 종전에는 화면의 각 위젯이 이벤트마다 [Gateway.call] 을 직접 불렀다. 그 경로에는
/// 두 가지 문제가 있었다.
///
/// 1. `package:http` 의 최상위 `post()` 는 호출마다 `Client()` 를 새로 만들고
///    닫는다. 즉 마우스 델타 하나가 새 TCP 연결 + 새 TLS 핸드셰이크를 치른다
///    (Cloudflare 터널 기준 실측 TCP 50.6ms + TLS 43.9ms = 약 95ms).
/// 2. 트랙패드 드래그의 `onScaleUpdate` 는 초당 60~120회 발생하는데 그걸 그대로
///    한 건씩 던졌다. await 도 하지 않으니 핸드셰이크가 동시에 수십 개 열리고,
///    손을 뗀 뒤에도 백로그가 계속 흘러 커서가 밀린다.
///
/// 여기서는 두 가지를 바꾼다.
///
/// * 스트리밍용 WebRTC 피어 연결에 이미 열려 있는 `input` 데이터 채널을 쓴다.
///   터널을 아예 지나가지 않는다. 채널이 없거나 닫혀 있으면 기존 HTTP 경로로
///   자동 폴백하므로 동작은 유지된다.
/// * 상대 이동은 누적해서 고정 주기로 한 번만 보낸다. 상대 이동은 더하기라서
///   합쳐도 최종 위치가 정확히 같다 — 이동량 손실 없이 요청 수만 줄어든다.
class RemoteInput {
  RemoteInput({required this.ip});

  /// 대상 머신 IP (HTTP 폴백에서 사용)
  final String ip;

  /// 상대 이동을 모아 보내는 주기.
  ///
  /// Arduino 쪽 consumer 가 명령 간 2ms 를 강제하고 USB HID 폴링도 8ms 단위라
  /// 이보다 촘촘히 보내봐야 큐만 쌓인다. 125Hz 면 손가락 움직임을 따라가기에
  /// 충분하면서 장치가 소화할 수 있는 상한 안쪽이다.
  static const Duration _flushInterval = Duration(milliseconds: 8);

  /// 보낼 게 없는 상태가 이만큼 이어지면 타이머를 멈춘다.
  static const int _idleTicksBeforeStop = 25;

  RTCDataChannel? _channel;
  Timer? _flushTimer;
  int _pendingDx = 0;
  int _pendingDy = 0;
  int _idleTicks = 0;
  bool _disposed = false;

  int _pingSeq = 0;
  final Map<int, Completer<Duration>> _pendingPings = {};
  final Map<int, Stopwatch> _pingClocks = {};

  /// 데이터 채널로 직접 보내고 있는지. false 면 HTTP 폴백 중이다.
  bool get isDirect =>
      _channel != null &&
      _channel!.state == RTCDataChannelState.RTCDataChannelOpen;

  /// 스트리머가 만든 `input` 채널을 넘겨받는다.
  void attachChannel(RTCDataChannel channel) {
    if (_disposed) return;
    _channel = channel;
    channel.onMessage = _onChannelMessage;
    debugPrint('RemoteInput: input channel attached (${channel.label})');
  }

  void detachChannel() {
    _channel = null;
    for (final completer in _pendingPings.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('input channel closed'));
      }
    }
    _pendingPings.clear();
    _pingClocks.clear();
  }

  void _onChannelMessage(RTCDataChannelMessage message) {
    if (message.isBinary) return;
    try {
      final data = jsonDecode(message.text);
      if (data is Map && data['t'] == 'pong') {
        final id = data['id'];
        final clock = _pingClocks.remove(id);
        final completer = _pendingPings.remove(id);
        if (clock != null && completer != null && !completer.isCompleted) {
          completer.complete(clock.elapsed);
        }
      }
    } catch (_) {
      // 채널로 들어오는 건 우리 스트리머뿐이지만, 형식이 어긋나도 무시한다.
    }
  }

  // ── 상대 이동 ────────────────────────────────────────────────────────────

  /// 상대 이동을 누적한다. 실제 전송은 [_flushInterval] 주기로 한 번씩 나간다.
  void moveBy(int dx, int dy) {
    if (_disposed || (dx == 0 && dy == 0)) return;
    _pendingDx += dx;
    _pendingDy += dy;
    _idleTicks = 0;
    _flushTimer ??= Timer.periodic(_flushInterval, (_) => _flush());
  }

  void _flush() {
    if (_disposed) return;

    if (_pendingDx == 0 && _pendingDy == 0) {
      if (++_idleTicks >= _idleTicksBeforeStop) {
        _flushTimer?.cancel();
        _flushTimer = null;
      }
      return;
    }

    final dx = _pendingDx;
    final dy = _pendingDy;
    _pendingDx = 0;
    _pendingDy = 0;
    _idleTicks = 0;

    if (!_send({'t': 'dmove', 'dx': dx, 'dy': dy})) {
      unawaited(_httpCall('inputHandler/mouse/dmove', {'dx': dx, 'dy': dy}));
    }
  }

  /// 큐에 남은 이동을 즉시 내보낸다. 클릭 직전처럼 순서가 중요한 때 쓴다.
  void flushPending() => _flush();

  // ── 그 외 이벤트 ────────────────────────────────────────────────────────

  Future<void> click(String button, {int? x, int? y}) async {
    if (_disposed) return;
    // 클릭 전에 밀린 이동을 먼저 내보내야 좌표가 어긋나지 않는다.
    flushPending();

    final payload = <String, dynamic>{'t': 'click', 'button': button, 'delay': 0};
    final params = <String, dynamic>{'click_mode': button, 'delay': 0};
    if (x != null && y != null) {
      payload['x'] = x;
      payload['y'] = y;
      params['x'] = x;
      params['y'] = y;
    }
    if (!_send(payload)) {
      await _httpCall('inputHandler/mouse/click', params);
    }
  }

  /// 절대 좌표 이동. 호스트에서 human trajectory 로 수백 ms 걸리는 경로다.
  Future<void> moveTo(int x, int y) async {
    if (_disposed) return;
    flushPending();
    if (!_send({'t': 'move', 'x': x, 'y': y})) {
      await _httpCall('inputHandler/mouse/move', {'x': x, 'y': y});
    }
  }

  Future<void> pressKey(String keyName) async {
    if (_disposed) return;
    if (!_send({'t': 'key', 'a': 'press', 'k': keyName})) {
      await _httpCall('inputHandler/press_key', {'key_name': keyName});
    }
  }

  Future<void> releaseKey(String keyName) async {
    if (_disposed) return;
    if (!_send({'t': 'key', 'a': 'release', 'k': keyName})) {
      await _httpCall('inputHandler/release_key', {'key_name': keyName});
    }
  }

  Future<void> releaseAll() async {
    if (_disposed) return;
    if (!_send({'t': 'releaseAll'})) {
      await _httpCall('inputHandler/releaseAll', null);
    }
  }

  /// 입력 채널 왕복 시간. 채널이 없으면 null.
  Future<Duration?> ping({Duration timeout = const Duration(seconds: 2)}) async {
    if (!isDirect) return null;
    final id = _pingSeq++;
    final completer = Completer<Duration>();
    _pendingPings[id] = completer;
    _pingClocks[id] = Stopwatch()..start();
    if (!_send({'t': 'ping', 'id': id})) {
      _pendingPings.remove(id);
      _pingClocks.remove(id);
      return null;
    }
    try {
      return await completer.future.timeout(timeout);
    } catch (_) {
      _pendingPings.remove(id);
      _pingClocks.remove(id);
      return null;
    }
  }

  // ── 내부 ────────────────────────────────────────────────────────────────

  /// 데이터 채널로 보낸다. 보내지 못했으면 false — 호출자가 HTTP 로 폴백한다.
  bool _send(Map<String, dynamic> payload) {
    final channel = _channel;
    if (channel == null ||
        channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      return false;
    }
    try {
      channel.send(RTCDataChannelMessage(jsonEncode(payload)));
      return true;
    } catch (e) {
      debugPrint('RemoteInput: channel send failed, falling back to HTTP: $e');
      return false;
    }
  }

  Future<void> _httpCall(String api, Map<String, dynamic>? params) async {
    try {
      await Gateway.call(ip, api, method: 'POST', params: params);
    } catch (e) {
      debugPrint('RemoteInput: $api failed: $e');
    }
  }

  void dispose() {
    _disposed = true;
    _flushTimer?.cancel();
    _flushTimer = null;
    detachChannel();
  }
}
