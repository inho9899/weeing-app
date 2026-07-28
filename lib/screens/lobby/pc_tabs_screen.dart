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
  bool _needsAttention = false;
  bool _showTabBar = false; // LobbyScreen의 트랙패드 모드일 때만 true

  void _onCaptchaStateChanged(CaptchaState state) {
    final needsAttention = state != CaptchaState.none;
    if (needsAttention != _needsAttention) {
      setState(() => _needsAttention = needsAttention);
    }
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
              deviceId: widget.deviceId,
              onStateChanged: _onCaptchaStateChanged,
            ),
          ],
        ),
      ),
    );
  }
}
