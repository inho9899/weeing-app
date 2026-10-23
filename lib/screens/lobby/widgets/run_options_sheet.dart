import 'package:flutter/material.dart';

/// 캐릭터별로 끌 수 있는 준비·정리 단계와 거짓말 탐지기 자동 풀이. 키는 봇(mainAction preprocess/postprocess,
/// intrAction 인터럽트)이 Start 의 skip 쿼리로 받는 이름이라 바꾸면 안 된다. 사냥터 입장은 항상 하므로 없다.
/// 탐지기를 끄면 봇이 풀지 않고 멈춘다(사람이 풀고 재개). type 은 꺼도 캡차 GIF 는 앱에 올라온다.
const runStepGroups = <String, Map<String, String>>{
  'preprocess': {
    // 끄면 봇이 기억해 둔 키세팅 대신 매번 키세팅 창을 열어 다시 읽는다
    'keymap_cache': '키세팅 저장값 사용 (끄면 매번 새로 읽음)',
    'luna_petite': '루나 쁘띠 펫 확인',
    'arcane_quest': '일퀘 (아케인리버)',
    'daily_quest': '일퀘 (그란디스)',
    'doping': '도핑',
    'artifact': '아티팩트 연장',
    'union_wealth': '유니온의 부',
  },
  'postprocess': {
    'union_coin': '유니온 코인',
    'daily_gift': '데일리 기프트',
  },
  'interrupt': {
    'type': '탐지기 자동 풀이 (캡차 입력)',
    'dongnama': '탐지기 자동 풀이 (올바른 문장)',
    'shape': '탐지기 자동 풀이 (도형)',
    'viol': '탐지기 자동 풀이 (바이올렛)',
  },
};

/// [skip] 에 든 단계의 이름 — 로비에 "꺼짐: …" 으로 보여줄 때 쓴다.
List<String> runStepLabels(List<String> skip) => [
      for (final steps in runStepGroups.values)
        for (final e in steps.entries)
          if (skip.contains(e.key)) e.value,
    ];

/// [character] 의 준비·정리 단계 스위치. 바꿀 때마다 끈 단계 목록을 [onChanged] 로 넘긴다
/// (저장 버튼 없이 바로 저장). 값은 Start 를 누를 때 봇에 넘어가므로, 돌고 있는 빌드에는 반영되지 않는다.
Future<void> showRunOptionsSheet(
  BuildContext context, {
  required String character,
  required List<String> skip,
  required ValueChanged<List<String>> onChanged,
}) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
    ),
    builder: (_) => _RunOptionsSheet(
      character: character,
      skip: skip,
      onChanged: onChanged,
    ),
  );
}

class _RunOptionsSheet extends StatefulWidget {
  final String character;
  final List<String> skip;
  final ValueChanged<List<String>> onChanged;

  const _RunOptionsSheet({
    required this.character,
    required this.skip,
    required this.onChanged,
  });

  @override
  State<_RunOptionsSheet> createState() => _RunOptionsSheetState();
}

class _RunOptionsSheetState extends State<_RunOptionsSheet> {
  late final Set<String> _skip = widget.skip.toSet();

  void _toggle(String key, bool on) {
    setState(() => on ? _skip.remove(key) : _skip.add(key));
    widget.onChanged(_skip.toList());
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.character,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              '끈 단계는 다음 Start 부터 건너뛴다 (탐지기는 끄면 풀지 않고 멈춘다)',
              style: TextStyle(fontSize: 13, color: Colors.grey[600]),
            ),
            for (final group in runStepGroups.entries) ...[
              const SizedBox(height: 12),
              const Divider(height: 1),
              const SizedBox(height: 12),
              Text(
                group.key,
                style: TextStyle(fontSize: 13, color: Colors.grey[700]),
              ),
              for (final step in group.value.entries)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(step.value, style: const TextStyle(fontSize: 15)),
                  value: !_skip.contains(step.key),
                  onChanged: (on) => _toggle(step.key, on),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
