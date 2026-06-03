#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════╗
# ║  nco-back — 자가추출 단일파일 빌드 (payload 임베드)                        ║
# ║    Linux  : nco-back-installer.run  (셸 스텁 + tar.gz)                    ║
# ║    Windows: NCO-Installer.exe       (PE 스텁 + tar.gz + 8B footer)        ║
# ║    macOS  : NCO Installer.app       (payload를 Contents/Resources 내장)   ║
# ║                                                                          ║
# ║  copy 1개 파일(.run/.exe/.app) → 실행 시 payload 자동 추출 후 설치.        ║
# ║  (WSL·인터넷·로그인은 여전히 필요)                                         ║
# ║                                                                          ║
# ║  사용법:  bash build/build-selfextract.sh                                 ║
# ╚══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF/.." && pwd)"
G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; N='\033[0m'
ok(){ echo -e "${G}  ✓${N} $*"; }; info(){ echo -e "${C}  ▶${N} $*"; }; warn(){ echo -e "${Y}  ⚠${N} $*"; }

# ── 1. 스테이징: 설치에 필요한 것만 (자가추출 산출물·build·네이티브 바이너리 제외) ──
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
info "스테이징: 번들 구성요소 복사..."
mkdir -p "$STAGE/nco-back"
for item in install.sh install.ps1 install.bat install-mac.command install-linux.sh lib payload README.md manifest.json; do
  [ -e "$ROOT/$item" ] || { warn "없음(스킵): $item"; continue; }
  cp -a "$ROOT/$item" "$STAGE/nco-back/"
done
# secrets.enc 가 있으면 포함 (있을 때만)
[ -f "$ROOT/secrets/secrets.enc" ] && { mkdir -p "$STAGE/nco-back/secrets"; cp -a "$ROOT/secrets/secrets.enc" "$STAGE/nco-back/secrets/"; ok "secrets.enc 포함"; } || warn "secrets.enc 없음 — 미포함(설치 시 키 신규입력)"

# ── 2. 공통 아카이브 ──
info "tar.gz 아카이브 생성..."
ARC="$STAGE/bundle.tgz"
( cd "$STAGE/nco-back" && tar -czf "$ARC" . )
ARC_SIZE=$(stat -c%s "$ARC")
ok "bundle.tgz = $(du -h "$ARC" | cut -f1) ($ARC_SIZE bytes)"

# ── 3. Linux .run ──
info "Linux 자가추출 .run 조립..."
RUN="$ROOT/nco-back-installer.run"
cat "$SELF/stub_linux.sh" "$ARC" > "$RUN"
chmod +x "$RUN"
ok "nco-back-installer.run ($(du -h "$RUN" | cut -f1))"

# ── 4. Windows .exe ──
info "Windows 자가추출 .exe 조립..."
if command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
  x86_64-w64-mingw32-gcc -O2 -municode -o "$STAGE/stub_win.exe" "$SELF/stub_win.c" -lshell32
  # 8바이트 LE footer = 아카이브 크기
  python3 -c "import struct,sys; open(sys.argv[1],'wb').write(struct.pack('<Q', int(sys.argv[2])))" "$STAGE/footer8" "$ARC_SIZE"
  cat "$STAGE/stub_win.exe" "$ARC" "$STAGE/footer8" > "$ROOT/NCO-Installer.exe"
  ok "NCO-Installer.exe ($(du -h "$ROOT/NCO-Installer.exe" | cut -f1), $(file -b "$ROOT/NCO-Installer.exe" | cut -d, -f1))"
else
  warn "mingw 없음 — .exe 스킵 (sudo apt-get install gcc-mingw-w64-x86-64)"
fi

# ── 5. macOS .app (payload 내장) ──
info "macOS 자가포함 .app 조립..."
APP="$ROOT/NCO Installer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/nco-back"
cp -a "$STAGE/nco-back/." "$APP/Contents/Resources/nco-back/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>NCO Installer</string>
  <key>CFBundleDisplayName</key><string>NCO Installer</string>
  <key>CFBundleIdentifier</key><string>net.novaai.ncoback.installer</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>NCO-Installer</string>
  <key>LSMinimumSystemVersion</key><string>10.13</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
cat > "$APP/Contents/MacOS/NCO-Installer" <<'MACSH'
#!/bin/bash
# NCO Installer.app — payload 내장 자가포함 실행파일
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
RES="$HERE/../Resources/nco-back"
if [ ! -f "$RES/install.sh" ]; then
  osascript -e 'display dialog "번들이 손상되었습니다 (Resources/nco-back/install.sh 없음)." buttons {"확인"} with icon stop'
  exit 1
fi
# 읽기전용/App Translocation 대비: 쓰기가능 임시폴더로 복사 후 실행
TMP="$(mktemp -d)"
cp -a "$RES/." "$TMP/"
chmod +x "$TMP/install.sh" "$TMP/lib/"*.sh 2>/dev/null || true
osascript <<OSA
tell application "Terminal"
    activate
    do script "cd " & quoted form of "$TMP" & " && bash install.sh; echo; echo '(설치 종료 — 창을 닫아도 됩니다)'"
end tell
OSA
MACSH
chmod +x "$APP/Contents/MacOS/NCO-Installer"
ok "NCO Installer.app ($(du -sh "$APP" | cut -f1), payload 내장)"

echo ""
ok "자가추출 단일파일 빌드 완료 → $ROOT"
echo -e "    nco-back-installer.run   ($(du -h "$RUN" | cut -f1))"
[ -f "$ROOT/NCO-Installer.exe" ] && echo -e "    NCO-Installer.exe        ($(du -h "$ROOT/NCO-Installer.exe" | cut -f1))"
echo -e "    NCO Installer.app        ($(du -sh "$APP" | cut -f1))"
