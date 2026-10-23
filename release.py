"""앱 빌드 → 프록시에 배포. 폰의 앱이 다음에 켜질 때(또는 복귀할 때) 업데이트를 묻는다.

    python release.py                 # 빌드 번호 +1, release APK 빌드, ../weeing-proxy/data/app 에 배포
    python release.py --proxy-dir D:/x/weeing-proxy

하는 일:
1. pubspec.yaml 의 빌드 번호(version: X.Y.Z+N 의 N)를 올린다. 이미 배포된 번호보다도 크게.
2. flutter build apk --release (android/key.properties 의 release 키로 서명)
3. <proxy>/data/app/weeing.apk 를 바꾼 뒤 version.json 을 바꾼다(APK 는 하나만 둔다).
   순서가 반대면 앱이 새 번호를 보고 옛 APK 를 받는다. 둘 다 임시 파일에 쓰고 이름을
   바꿔서 반쯤 쓰인 파일이 내려가지 않게 한다.

프록시(utils/appupdate/router.py)는 이 폴더를 그대로 내려줄 뿐이라 재시작이 필요 없다.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--proxy-dir", default=str(ROOT.parent / "weeing-proxy"))
    args = parser.parse_args()

    app_dir = Path(args.proxy_dir) / "data" / "app"
    if not (Path(args.proxy_dir) / "utils" / "appupdate").is_dir():
        print(f"프록시 폴더가 아닙니다: {args.proxy_dir}")
        return 1

    # debug 키로 서명된 APK 는 release 키로 깔린 앱 위에 설치되지 않는다
    if not (ROOT / "android" / "key.properties").exists():
        print("android/key.properties 가 없습니다. release 키 없이 배포하면 폰에서 설치가 실패합니다.")
        return 1

    pubspec = ROOT / "pubspec.yaml"
    text = pubspec.read_text(encoding="utf-8")
    m = re.search(r"^version:\s*([0-9]+\.[0-9]+\.[0-9]+)(?:\+([0-9]+))?\s*$", text, re.M)
    if not m:
        print("pubspec.yaml 에서 version 을 찾지 못했습니다.")
        return 1
    version_name = m.group(1)

    deployed = 0
    try:
        deployed = json.loads((app_dir / "version.json").read_text(encoding="utf-8"))["build"]
    except FileNotFoundError:
        pass
    build = max(int(m.group(2) or 1), deployed) + 1

    pubspec.write_text(
        text[:m.start()] + f"version: {version_name}+{build}" + text[m.end():],
        encoding="utf-8",
    )
    print(f"빌드 {version_name}+{build} (배포돼 있던 빌드: {deployed or '없음'})")

    flutter = shutil.which("flutter")
    if not flutter:
        print("flutter 를 PATH 에서 찾지 못했습니다.")
        return 1
    built = subprocess.run([flutter, "build", "apk", "--release"], cwd=ROOT).returncode == 0
    # 빌드가 띄운 Gradle 데몬은 끝나도 남아 4~5GB 를 잡는다. 이 PC 는 봇도 같이 돌아서 2026-10-16 03:01 에
    # 시스템 메모리가 바닥나 captchaSolver·objectDetector 가 실패했다 — 빌드가 끝나면 바로 끈다
    subprocess.run([str(ROOT / "android" / "gradlew.bat"), "--stop"], cwd=ROOT / "android")
    if not built:
        print("빌드 실패. pubspec.yaml 의 번호는 올라간 채로 둔다 (다음 빌드가 또 올린다).")
        return 1

    apk = ROOT / "build" / "app" / "outputs" / "flutter-apk" / "app-release.apk"
    app_dir.mkdir(parents=True, exist_ok=True)
    target = app_dir / "weeing.apk"
    part = target.with_name(target.name + ".part")
    shutil.copyfile(apk, part)
    # 누가 받는 중이면 Windows 가 열린 파일을 못 바꾸게 막는다 — 끝날 때까지 기다린다
    for attempt in range(20):
        try:
            os.replace(part, target)
            break
        except PermissionError:
            if attempt == 19:
                print("weeing.apk 를 바꾸지 못했습니다 (다운로드가 계속 진행 중). 잠시 뒤 다시 실행하세요.")
                return 1
            time.sleep(3)

    data = target.read_bytes()
    info = {
        "build": build,
        "version": version_name,
        "size": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
        "built_at": datetime.now().isoformat(timespec="seconds"),
    }
    part = app_dir / "version.json.part"
    part.write_text(json.dumps(info, ensure_ascii=False, indent=2), encoding="utf-8")
    os.replace(part, app_dir / "version.json")

    print(f"배포 완료: {target} ({len(data) / 1e6:.1f} MB)")
    print("다운로드: https://api.nongameanbun.xyz/app/download")
    return 0


if __name__ == "__main__":
    sys.exit(main())
