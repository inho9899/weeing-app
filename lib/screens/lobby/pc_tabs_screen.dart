import 'package:flutter/material.dart';

import 'package:weeing_app/gateway/gateway.dart';
import 'captcha_help_screen.dart';
import 'lobby_screen.dart';

/// PC 하나를 열었을 때의 탭 컨테이너.
/// - 캡차 도움 탭의 상태(none이 아님 = 뭔가 진행/종료됨)를 추적해 "제어" 탭의
///   마우스 모드 화면에 빨간 느낌표로 알려준다.
/// - 상단 제어/캡차도움 탭바는 스트리밍·사이클 시간 입력 화면(기본 상태)에서는
///   숨기고, 마우스 모드(트랙패드) 화면일 때만 보여준다.
class PcTabsScreen extends StatefulWidget {
  final String ip;
  final String? deviceId;

  const PcTabsScreen({super.key, required this.ip, required this.deviceId});

  @override
  State<PcTabsScreen> createState() => _PcTabsScreenState();
}

class _PcTabsScreenState extends State<PcTabsScreen> {
  static const _redWindow = Duration(seconds: 60);

  bool _needsAttention = false;
  DateTime? _captchaOccurredAt;
  bool _showTabBar = false; // LobbyScreen의 트랙패드 모드일 때만 true

  void _onCaptchaStatusChanged(CaptchaStatus status) {
    final needsAttention = status.state != CaptchaState.none;
    setState(() {
      _needsAttention = needsAttention;
      _captchaOccurredAt = status.occurredAt;
    });
  }

  /// 캡차 발생 후 60초까지는 빨간불(응답 시급), 그 이후엔 검은불(확인은 필요하나 급하진 않음).
  /// 발생 시각을 알 수 없으면(구버전 서버 응답 등) 급한 쪽으로 오판하지 않게 검은불로 둔다.
  Color? get _badgeColor {
    if (!_needsAttention) return null;
    final occurredAt = _captchaOccurredAt;
    if (occurredAt == null) return Colors.black;
    return DateTime.now().difference(occurredAt) < _redWindow
        ? Colors.red
        : Colors.black;
  }

  void _onTrackpadModeChanged(bool trackpadMode) {
    if (trackpadMode != _showTabBar) {
      setState(() => _showTabBar = trackpadMode);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('PC 제어'),
          actions: [
            if (_badgeColor != null)
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Center(
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: _badgeColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
          ],
          bottom: _showTabBar
              ? const TabBar(
                  tabs: [
                    Tab(text: '제어'),
                    Tab(text: '캡차 도움'),
                  ],
                )
              : null,
        ),
        body: TabBarView(
          // 마우스 모드의 좌우 드래그(트랙패드 이동)가 탭 전환 스와이프와
          // 제스처 경합을 일으켜 화면이 밀리는 문제 방지 — 탭은 탭바 탭으로만 전환.
          physics: const NeverScrollableScrollPhysics(),
          children: [
            LobbyScreen(
              ip: widget.ip,
              captchaNeedsAttention: _needsAttention,
              onTrackpadModeChanged: _onTrackpadModeChanged,
            ),
            CaptchaHelpScreen(
              ip: widget.ip,
              deviceId: widget.deviceId,
              onStatusChanged: _onCaptchaStatusChanged,
            ),
          ],
        ),
      ),
    );
  }
}
