/// 스케줄 계획·상태 모델. 키 이름은 프록시(weeing-proxy utils/schedule/router.py)가 받고 주는 그대로라 바꾸면 안 된다.
library;

/// 블록 하나. 로그인(계정) → 사이클(캐릭터·빌드·사이클 수·끈 단계) → 로그아웃 순으로 쌓고, 사이에 대기(N분 또는 HH:MM 까지)를 둘 수 있다.
class ScheduleBlock {
  static const login = 'login';
  static const cycle = 'cycle';
  static const logout = 'logout';
  static const wait = 'wait';

  final String type;
  String account; // login: PC 계정 목록(subAction macros)의 이름
  String character; // cycle: 캐릭터명 (빌드 매핑의 키)
  String build; // cycle: 빌드명 (mainAction start 에 그대로 간다)
  int cycles; // cycle: 사이클 수 (statusChecker cycle/set)
  List<String> skip; // cycle: 끈 준비·정리 단계 키 (run_options_sheet 의 runStepGroups)
  int minutes; // wait: 기다릴 분 (until 이 비어 있을 때)
  String until; // wait: 오늘 이 시각까지 "HH:MM". 비어 있으면 minutes 로 기다린다

  ScheduleBlock({
    required this.type,
    this.account = '',
    this.character = '',
    this.build = '',
    this.cycles = 10,
    List<String>? skip,
    this.minutes = 30,
    this.until = '',
  }) : skip = skip ?? [];

  factory ScheduleBlock.fromJson(Map<String, dynamic> json) => ScheduleBlock(
        type: (json['type'] ?? '').toString(),
        account: (json['account'] ?? '').toString(),
        character: (json['character'] ?? '').toString(),
        build: (json['build'] ?? '').toString(),
        cycles: (json['cycles'] as num?)?.toInt() ?? 10,
        skip: (json['skip'] as List?)?.map((e) => e.toString()).toList() ?? [],
        minutes: (json['minutes'] as num?)?.toInt() ?? 30,
        until: (json['until'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() => switch (type) {
        login => {'type': type, 'account': account},
        cycle => {
            'type': type,
            'character': character,
            'build': build,
            'cycles': cycles,
            'skip': skip,
          },
        wait => until.isNotEmpty ? {'type': type, 'until': until} : {'type': type, 'minutes': minutes},
        _ => {'type': type},
      };

  String get title => switch (type) {
        login => '로그인',
        cycle => '사이클',
        logout => '로그아웃',
        wait => '대기',
        _ => type,
      };

  /// 대기 블록의 한 줄 설명 ("30분" / "14:00 까지").
  String get waitText => until.isNotEmpty ? '$until 까지' : '$minutes분';

  /// 사이클 수로 어림한 소요 시간 ("약 5시간 30분"). 사이클 하나를 30분으로 본다.
  String get durationText => hoursText(cycles);

  static String hoursText(int cycles) {
    final minutes = cycles * 30;
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return m == 0 ? '$h시간' : '$h시간 $m분';
  }
}

class SchedulePlan {
  String start; // 첫 블록 시작 시각 "HH:MM"
  final List<ScheduleBlock> blocks;

  SchedulePlan({this.start = '09:00', List<ScheduleBlock>? blocks}) : blocks = blocks ?? [];

  factory SchedulePlan.fromJson(Map<String, dynamic> json) => SchedulePlan(
        start: (json['start'] ?? '09:00').toString(),
        blocks: ((json['blocks'] as List?) ?? [])
            .whereType<Map>()
            .map((e) => ScheduleBlock.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'start': start,
        'blocks': blocks.map((b) => b.toJson()).toList(),
      };

  int get totalCycles =>
      blocks.where((b) => b.type == ScheduleBlock.cycle).fold(0, (sum, b) => sum + b.cycles);

  static int _minutesOf(String hhmm, int fallback) {
    final parts = hhmm.split(':');
    if (parts.length != 2) return fallback;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    return h == null || m == null ? fallback : h * 60 + m;
  }

  /// 시작 시각부터 블록을 차례로 더해 어림한 종료 시각. 사이클은 30분씩, 로그인·로그아웃은 3분, 대기는 그 분만큼,
  /// 시각까지 대기는 그 시각으로 건너뛴다(이미 지났으면 안 기다린다).
  String get endTimeText {
    var clock = _minutesOf(start, 9 * 60);
    for (final b in blocks) {
      switch (b.type) {
        case ScheduleBlock.cycle:
          clock += b.cycles * 30 + 3;
        case ScheduleBlock.wait:
          if (b.until.isNotEmpty) {
            final target = _minutesOf(b.until, clock);
            if (target > clock) clock = target;
          } else {
            clock += b.minutes;
          }
        default:
          clock += 3;
      }
    }
    final h = (clock ~/ 60) % 24;
    final m = clock % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }
}

/// GET /schedule/plan/{device} 응답.
class ScheduleInfo {
  final String ip;
  final bool enabled;
  final bool running;
  final SchedulePlan plan;
  final Map<String, dynamic> state;

  const ScheduleInfo({
    required this.ip,
    required this.enabled,
    required this.running,
    required this.plan,
    required this.state,
  });

  factory ScheduleInfo.fromJson(Map<String, dynamic> json) => ScheduleInfo(
        ip: (json['ip'] ?? '').toString(),
        enabled: json['enabled'] == true,
        running: json['running'] == true,
        plan: SchedulePlan.fromJson(Map<String, dynamic>.from((json['plan'] as Map?) ?? {})),
        state: Map<String, dynamic>.from((json['state'] as Map?) ?? {}),
      );
}

/// GET /schedule/status/{device} 응답 — 로비 한 줄과 스케줄 화면 상단에 쓴다.
class ScheduleStatus {
  final bool exists;
  final bool enabled;
  final bool running;
  final String start;
  final List<String> blocks; // 블록 라벨 ("로그인(메인)", "사이클(아델)", "로그아웃")
  final Map<String, dynamic> state;

  const ScheduleStatus({
    required this.exists,
    required this.enabled,
    required this.running,
    required this.start,
    required this.blocks,
    required this.state,
  });

  factory ScheduleStatus.fromJson(Map<String, dynamic> json) => ScheduleStatus(
        exists: json['exists'] == true,
        enabled: json['enabled'] == true,
        running: json['running'] == true,
        start: (json['start'] ?? '09:00').toString(),
        blocks: ((json['blocks'] as List?) ?? []).map((e) => e.toString()).toList(),
        state: Map<String, dynamic>.from((json['state'] as Map?) ?? {}),
      );

  static String _today() {
    final d = DateTime.now();
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  int? get step => state['step'] is int ? state['step'] as int : null;
  bool get ranToday => state['run_date'] == _today();
  List<Map<String, dynamic>> get results =>
      ((state['results'] as List?) ?? []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  int get succeeded => results.where((r) => r['ok'] == true).length;

  String get _todayWord {
    final phase = state['phase'];
    return phase == 'done' ? '완료' : phase == 'stopped' ? '중단' : '실패';
  }

  /// 끝나면 프록시가 OFF 로 돌리므로, OFF 라도 오늘 돈 기록이 있으면 결과를 보여준다.
  String get headline {
    if (!exists || !enabled) {
      return exists && ranToday ? '스케줄 OFF · 오늘 $_todayWord ($succeeded/${blocks.length} 성공)' : '스케줄 OFF';
    }
    final s = step;
    if (running && s != null && s < blocks.length) {
      return '스케줄 ON · ${s + 1}/${blocks.length} ${blocks[s]} 진행 중';
    }
    if (running) return '스케줄 ON · 진행 중';
    return '스케줄 ON · $start 시작 대기 · 블록 ${blocks.length}개';
  }

  String get detail {
    if (!exists || !enabled) {
      if (!exists || !ranToday) return '탭해서 설정';
      final failed = results.where((r) => r['ok'] != true).toList();
      if (failed.isNotEmpty) return '${failed.first['label']}: ${failed.first['message']}';
      final message = (state['message'] ?? '').toString();
      return message.isNotEmpty ? message : '다시 켜면 다시 돈다';
    }
    final s = step;
    if (running && s != null) {
      return s + 1 < blocks.length ? '다음 ${blocks[s + 1]}' : '마지막 블록';
    }
    return '시작 시각이 지났으면 바로 돈다 · 끝나면 OFF';
  }
}
