import 'dart:async';
import 'package:flutter/material.dart';

import 'package:weeing_app/gateway/gateway.dart';

/// PC(typeliecheck)가 자동으로 못 푸는 왜곡 캡차를 GIF로 올려두면,
/// 여기서 보고 답을 입력해 제출한다. PC는 그 답을 폴링해서 받아 직접 타이핑한다.
///
/// 캡차가 실제로 진행 중일 때(pending/processing)만 입력 UI를 보여준다 —
/// none/resolved/failed일 땐 안내 메시지만 표시하고 입력창 자체를 숨긴다.
class CaptchaHelpScreen extends StatefulWidget {
  final String? deviceId;

  /// 상태가 바뀔 때마다 호출된다 — PcTabsScreen이 이걸로 탭에 빨간 배지를 띄운다.
  final ValueChanged<CaptchaState>? onStateChanged;

  const CaptchaHelpScreen({super.key, required this.deviceId, this.onStateChanged});

  @override
  State<CaptchaHelpScreen> createState() => _CaptchaHelpScreenState();
}

class _CaptchaHelpScreenState extends State<CaptchaHelpScreen> {
  static const _normalInterval = Duration(seconds: 2);
  static const _fastInterval = Duration(seconds: 1);
  static const _fastBurstTicks = 8; // 제출 직후 이 횟수만큼 빠르게(1초) 재폴링

  Timer? _pollTimer;
  int _fastTicksLeft = 0;
  CaptchaState _state = CaptchaState.none;
  bool _submitting = false;
  int _gifNonce = 0; // 폴링마다 바꿔서 Image.network가 새로 받아오게 함
  final TextEditingController _answerController = TextEditingController();

  @override
  void initState() {
    super.initState();
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
    final state = await Gateway.fetchCaptchaState(deviceId);
    if (!mounted) return;
    if (state != _state) {
      widget.onStateChanged?.call(state);
    }
    setState(() {
      _state = state;
      _gifNonce++;
    });
  }

  Future<void> _submit() async {
    final deviceId = widget.deviceId;
    if (deviceId == null) return;
    final answer = _answerController.text.trim();
    if (answer.isEmpty) return;

    setState(() => _submitting = true);
    final ok = await Gateway.submitCaptchaAnswer(deviceId, answer);
    if (!mounted) return;
    setState(() => _submitting = false);

    final messenger = ScaffoldMessenger.of(context);
    if (ok) {
      _answerController.clear();
      messenger.showSnackBar(const SnackBar(content: Text('답을 전송했습니다, 확인 중...')));
      // 오답이면 PC가 곧 다음 시도 GIF를 새로 올리고, 정답/기회소진이면 종료
      // 상태로 바뀐다 — 이 전환을 빨리 잡기 위해 잠깐 빠르게 재폴링한다.
      _fastTicksLeft = _fastBurstTicks;
      _startTimer(_fastInterval);
      _poll();
    } else {
      messenger.showSnackBar(const SnackBar(content: Text('전송 실패 - 다시 시도해주세요')));
    }
  }

  @override
  Widget build(BuildContext context) {
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
