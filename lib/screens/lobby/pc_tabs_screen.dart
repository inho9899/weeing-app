import 'dart:async';

import 'package:flutter/material.dart';

import 'package:weeing_app/gateway/gateway.dart';
import 'captcha_help_screen.dart';
import 'lobby_screen.dart';
import 'services/lobby_api_service.dart';

/// PC 하나를 열었을 때의 탭 컨테이너.
/// - 캡차 도움 탭의 상태(none이 아님 = 뭔가 진행/종료됨)를 추적해 "제어" 탭의
///   마우스 모드 화면에 빨간 느낌표로 알려준다.
/// - 상단 제어/캡차도움 탭바는 스트리밍·사이클 시간 입력 화면(기본 상태)에서는
///   숨기고, 마우스 모드(트랙패드) 화면일 때만 보여준다.
/// - 앱바에 입력 제어(inputHandler on/off) 스위치를 둔다. 로비 화면이 아니라
///   여기 있는 이유는 이게 화면 단위가 아니라 PC 단위 차단 스위치이기 때문이다
///   — 끄면 러너든 트랙패드든 그 PC 로 나가는 입력이 전부 막히므로, 어느 탭을
///   보고 있든 상태가 보이고 끌 수 있어야 한다.
class PcTabsScreen extends StatefulWidget {
  final String ip;
  final String? deviceId;

  const PcTabsScreen({super.key, required this.ip, required this.deviceId});

  @override
  State<PcTabsScreen> createState() => _PcTabsScreenState();
}

class _PcTabsScreenState extends State<PcTabsScreen> with WidgetsBindingObserver {
  static const _redWindow = Duration(seconds: 60);

  bool _needsAttention = false;
  DateTime? _captchaOccurredAt;
  bool _showTabBar = false; // LobbyScreen의 트랙패드 모드일 때만 true

  // ===== 입력 제어(inputHandler on/off) =====
  late final LobbyApiService _api;
  Timer? _inputStateTimer;

  // null = 아직 모름(조회 전/실패). 이 상태는 앱 전용이 아니라 PC 공유 상태다 —
  // 러너(mainAction runner)나 agentServer 도 on/off 를 바꾸므로, 앱이 마지막으로
  // 누른 값을 그대로 믿지 않고 주기적으로 서버 값을 따라간다.
  bool? _inputEnabled;

  // 토글 요청이 나가 있는 동안엔 폴링 결과로 값을 덮지 않는다. 명령이 반영되기
  // 전의 옛 값이 돌아와 스위치가 되튕기는 걸 막기 위함.
  bool _inputToggleInFlight = false;

  @override
  void initState() {
    super.initState();
    _api = LobbyApiService(ip: widget.ip);
    WidgetsBinding.instance.addObserver(this);

    _fetchInputEnabled();
    _inputStateTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _fetchInputEnabled(),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _inputStateTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // 백그라운드 동안 다른 주체가 바꿨을 수 있다.
    if (state == AppLifecycleState.resumed) _fetchInputEnabled();
  }

  /// 입력 제어 on/off 상태 조회 (진입 시 1회 + 3초 폴링 + 앱 복귀 시).
  Future<void> _fetchInputEnabled() async {
    final enabled = await _api.fetchInputEnabled();
    if (!mounted) return;
    if (_inputToggleInFlight) return;  // _inputToggleInFlight 주석 참고
    if (_inputEnabled == enabled) return;
    setState(() => _inputEnabled = enabled);
  }

  /// 입력 제어 스위치 토글.
  ///
  /// off 는 대상 PC 의 입력을 즉시 끊는 차단 스위치다 — 러너가 도는 중에도
  /// 막지 않는다(그게 이 스위치의 목적). 다만 러너는 계속 진행한다고 믿은 채
  /// 입력만 안 나가는 상태가 되므로, 껐다는 사실을 스낵바로 남긴다.
  Future<void> _handleInputToggle(bool enabled) async {
    setState(() {
      _inputEnabled = enabled;   // 낙관적 반영 (폴링이 뒤에 바로잡는다)
      _inputToggleInFlight = true;
    });

    final ok = await _api.setInputEnabled(enabled);
    if (!mounted) return;

    _inputToggleInFlight = false;

    if (!ok) {
      // 실패했으면 지금 상태를 모르는 것이므로 "모름"으로 되돌리고 재조회한다.
      setState(() => _inputEnabled = null);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('입력 제어 전환에 실패했습니다')),
      );
      _fetchInputEnabled();
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          enabled
              ? '입력 제어를 켰습니다'
              : '입력을 차단했습니다 — 러너·트랙패드 입력이 모두 나가지 않습니다',
        ),
      ),
    );

    // 실제 반영값으로 한 번 확인 (다른 주체가 동시에 바꿨을 수도 있다).
    _fetchInputEnabled();
  }

  /// 앱바의 입력 제어 스위치. 조회 전/실패(null)면 비활성으로 흐리게 둔다 —
  /// "모름"을 "꺼짐"으로 보여주면, 켜려고 누른 토글이 이미 켜져 있던 PC 를
  /// 도리어 끄게 된다.
  Widget _buildInputSwitch() {
    final known = _inputEnabled != null;
    final on = _inputEnabled ?? false;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          !known
              ? '입력 ?'
              : on
                  ? '입력 ON'
                  : '입력 OFF',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: !known
                ? Colors.grey
                : on
                    ? Colors.green
                    : Colors.grey,
          ),
        ),
        Switch(
          value: on,
          onChanged: known ? _handleInputToggle : null,
          activeColor: Colors.green,
        ),
      ],
    );
  }

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
                padding: const EdgeInsets.only(right: 4),
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
            _buildInputSwitch(),
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
