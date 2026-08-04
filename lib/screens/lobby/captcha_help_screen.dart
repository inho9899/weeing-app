import 'dart:async';
import 'package:flutter/material.dart';

import 'package:weeing_app/gateway/gateway.dart';
import 'services/lobby_api_service.dart';

/// PC(typeliecheck)가 자동으로 못 푸는 왜곡 캡차를 GIF로 올려두면,
/// 여기서 보고 답을 입력해 제출한다. 제출한 답은 대상 PC의 subAction
/// (`/input/sequence`)으로 직행해 그대로 타이핑된다 — [_submit] 참고.
///
/// 캡차가 실제로 진행 중일 때(pending/processing)만 입력 UI를 보여준다 —
/// none/resolved/failed일 땐 안내 메시지만 표시하고 입력창 자체를 숨긴다.
class CaptchaHelpScreen extends StatefulWidget {
  final String ip;
  final String? deviceId;

  /// 폴링할 때마다 호출된다(상태 전환 여부와 무관) — PcTabsScreen이 이걸로
  /// AppBar 배지의 발생 후 경과 시간을 계속 갱신한다.
  final ValueChanged<CaptchaStatus>? onStatusChanged;

  const CaptchaHelpScreen({
    super.key,
    required this.ip,
    required this.deviceId,
    this.onStatusChanged,
  });

  @override
  State<CaptchaHelpScreen> createState() => _CaptchaHelpScreenState();
}

class _CaptchaHelpScreenState extends State<CaptchaHelpScreen> {
  static const _normalInterval = Duration(seconds: 2);
  static const _fastInterval = Duration(seconds: 1);
  static const _fastBurstTicks = 8; // 제출 직후 이 횟수만큼 빠르게(1초) 재폴링

  late final LobbyApiService _api;
  Timer? _pollTimer;
  int _fastTicksLeft = 0;
  CaptchaState _state = CaptchaState.none;
  bool _submitting = false;
  int _gifNonce = 0; // 폴링마다 바꿔서 Image.network가 새로 받아오게 함
  final TextEditingController _answerController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _api = LobbyApiService(ip: widget.ip);
    if (widget.deviceId != null) {
      _poll();
      _startTimer(_normalInterval);
    }
  }

  void _startTimer(Duration interval) {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(interval, (_) => _onTick());
  }

  void _onTick() {
    _poll();
    if (_fastTicksLeft > 0) {
      _fastTicksLeft--;
      if (_fastTicksLeft == 0) {
        _startTimer(_normalInterval); // 빠른 폴링 구간 종료, 평상시 주기로 복귀
      }
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _answerController.dispose();
    super.dispose();
  }

  Future<void> _poll() async {
    final deviceId = widget.deviceId;
    if (deviceId == null) return;
    final status = await Gateway.fetchCaptchaState(deviceId);
    if (!mounted) return;
    widget.onStatusChanged?.call(status);
    setState(() {
      _state = status.state;
      _gifNonce++;
    });
  }

  /// 캡차 답을 PC에 직접 타이핑시킨다 (subAction `/input/sequence`).
  ///
  /// 예전엔 cloudfare `/captcha/answer` 에 답을 올려두고 PC가 폴링해 가져가는
  /// 방식이었는데, PC 쪽 handle_type()이 GIF만 올리고 바로 wait 로 빠지도록
  /// 바뀌면서 그 답을 가져가는 주체가 없어졌다. 게다가 cloudfare 에 답을 올리면
  /// 서버 상태가 answered -> 앱에서 "processing" 으로 읽혀 입력폼이 잠기는데,
  /// resolve/fail 을 보고하는 곳도 없어 영원히 안 풀린다. 그래서 중계를 거치지
  /// 않고 대상 PC 로 직행시킨다.
  Future<void> _submit() async {
    final answer = _answerController.text.trim();
    if (answer.isEmpty) return;

    setState(() => _submitting = true);
    final error = await _api.sendInputSequence(answer);
    if (!mounted) return;
    setState(() => _submitting = false);

    final messenger = ScaffoldMessenger.of(context);
    if (error == null) {
      _answerController.clear();
      messenger.showSnackBar(const SnackBar(content: Text('답을 PC에 입력했습니다')));
      // 입력 후 캡차가 닫혔는지(=새 상태) 빨리 잡기 위해 잠깐 빠르게 재폴링한다.
      _fastTicksLeft = _fastBurstTicks;
      _startTimer(_fastInterval);
      _poll();
    } else {
      messenger.showSnackBar(SnackBar(content: Text(error)));
    }
  }

  @override
  Widget build(BuildContext context) {
    // PcTabsScreen의 Scaffold(TabBarView)는 SafeArea를 감싸주지 않는다 —
    // LobbyScreen(제어 탭)은 자체 Scaffold+SafeArea로 하단 시스템 바를
    // 피하지만, 이 탭은 없어서 내용이 시스템 바 아래로 깔릴 수 있다.
    // 여기서 직접 SafeArea로 감싼다.
    return SafeArea(top: false, child: _buildCaptchaArea());
  }

  Widget _buildCaptchaArea() {
    final deviceId = widget.deviceId;
    if (deviceId == null) {
      return _message(
        '이 기기는 device ID가 없어 캡차 도움 기능을 쓸 수 없습니다.\n기기를 삭제 후 다시 등록해주세요.',
      );
    }

    switch (_state) {
      case CaptchaState.none:
        return _message('대기 중인 캡차가 없습니다');
      case CaptchaState.resolved:
        return _buildEndState(
          deviceId,
          text: '정답입니다! 캡차가 해결되었습니다',
          icon: Icons.check_circle,
          color: Colors.green,
        );
      case CaptchaState.failed:
        return _buildEndState(
          deviceId,
          text: '시간 내에 해결하지 못했습니다.\n"제어" 탭에서 직접 확인해주세요.',
          icon: Icons.error_outline,
          color: Colors.redAccent,
        );
      case CaptchaState.processing:
        return _buildForm(deviceId, processing: true);
      case CaptchaState.pending:
        return _buildForm(deviceId, processing: false);
    }
  }

  Widget _message(String text, {IconData? icon, Color? color}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 40, color: color),
              const SizedBox(height: 12),
            ],
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(color: color ?? Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  /// resolved/failed 종료 상태 — 마지막으로 시도한 GIF를 계속 보여줘서
  /// 사용자가 무슨 문구였는지 확인할 수 있게 한다(입력 폼은 숨김).
  Widget _buildEndState(
    String deviceId, {
    required String text,
    required IconData icon,
    required Color color,
  }) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: AspectRatio(
              aspectRatio: 1,
              child: Image.network(
                '${Gateway.captchaGifUrl(deviceId)}?v=$_gifNonce',
                fit: BoxFit.contain,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) => const Center(child: Text('이미지 로드 실패')),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Icon(icon, size: 40, color: color),
          const SizedBox(height: 12),
          Text(text, textAlign: TextAlign.center, style: TextStyle(color: color)),
        ],
      ),
    );
  }

  Widget _buildForm(String deviceId, {required bool processing}) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Text(
            processing ? '답을 확인하는 중입니다...' : '아래 이미지 속 문구를 보고 답을 입력하세요',
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 12),
          // 캡차 다이얼로그는 화면 해상도와 무관한 고정 픽셀 크기라 항상 정사각형에
          // 가깝다(liecheck_251129.onnx 실측: tc1 245x245, tc2 247x246). GIF 자체
          // 픽셀 크기와 무관하게 항상 정사각형으로 보이도록 고정한다.
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: AspectRatio(
              aspectRatio: 1,
              child: Image.network(
                '${Gateway.captchaGifUrl(deviceId)}?v=$_gifNonce',
                fit: BoxFit.contain,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) => const Center(child: Text('이미지 로드 실패')),
              ),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _answerController,
            enabled: !processing,
            decoration: const InputDecoration(
              labelText: '답',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: (processing || _submitting) ? null : _submit,
              child: (_submitting || processing)
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('제출'),
            ),
          ),
        ],
      ),
    );
  }
}
