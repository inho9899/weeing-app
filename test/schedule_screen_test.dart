import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:weeing_app/screens/lobby/widgets/schedule_strip.dart';
import 'package:weeing_app/screens/schedule/models/schedule_plan.dart';
import 'package:weeing_app/screens/schedule/schedule_screen.dart';

/// 기기 없이 레이아웃이 깨지지 않는지 본다. 프록시·PC 호출은 Gateway 주소가 없어 바로 실패하고
/// 빈 목록으로 떨어지므로, 화면은 뜨고 블록을 쌓을 수 있어야 한다.
/// 0.1.0+21 에서 블록 카드(Row stretch + Expanded 연결선)가 ListView 의 무한 높이를 받아 겹쳐 보였다.
void main() {
  testWidgets('스케줄 화면: 블록 셋을 쌓아도 레이아웃 예외가 없다', (tester) async {
    SharedPreferences.setMockInitialValues({});
    // ListView 는 보이는 만큼만 만든다 — 블록 넷이 다 그려지게 화면을 길게 잡는다
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: ScheduleScreen(ip: '127.0.0.1', deviceKey: 'test-device')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('첫 블록 시작'), findsOneWidget);

    for (final label in ['로그인', '사이클', '로그아웃', '사이클']) {
      await tester.tap(find.widgetWithText(InkWell, label).last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '$label 블록을 추가하다 레이아웃 예외');
    }
    expect(find.text('약 5시간'), findsNWidgets(2)); // 사이클 10 기본값 두 개
    expect(find.text('4'), findsOneWidget); // 네 번째 블록 번호

    // 삭제 뒤에도 멀쩡해야 한다
    await tester.tap(find.byTooltip('블록 삭제').first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('4'), findsNothing);

    // 주기 타이머를 끝내려고 화면을 내린다
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('로비 한 줄: 상태별 문구', (tester) async {
    const off = ScheduleStatus(exists: false, enabled: false, running: false, start: '09:00', blocks: [], state: {});
    final running = ScheduleStatus(
      exists: true, enabled: true, running: true, start: '09:00',
      blocks: const ['로그인(A)', '사이클(c1)', '로그아웃'],
      state: const {'phase': 'running', 'step': 1, 'run_date': '2026-11-03', 'results': []},
    );
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Column(children: [
      ScheduleStrip(status: off, onTap: () {}),
      ScheduleStrip(status: running, onTap: () {}),
      ScheduleStrip(status: null, onTap: () {}),
    ]))));
    expect(tester.takeException(), isNull);
    expect(find.text('스케줄 OFF'), findsOneWidget);
    expect(find.text('스케줄 ON · 2/3 사이클(c1) 진행 중'), findsOneWidget);
    expect(find.text('다음 로그아웃'), findsOneWidget);
    expect(find.text('스케줄 확인 중'), findsOneWidget);
  });
}
