# nova-fleet-config — 플릿 환경 SSOT (Single Source of Truth)

inter-session 메시에 연결된 모든 Claude 세션이 **동일한 공유 환경**을 유지하기 위한 정본.
canonical 호스트(claude-3, WSL family)의 공유 설정을 여기에 두고, 각 머신은
`install/apply.sh`로 **경로 치환 후 적용**한다. 비밀·OS전용은 제외.

## 레이아웃
```
claude/
  hooks/            # ~/.claude/hooks/*.sh (공유 훅 — 머신경로는 {{HOME}} 템플릿)
  commands/         # ~/.claude/commands/*.md
  skills/           # 공유 스킬(머신전용 hwp 등은 제외)
  settings.template.json   # ~/.claude/settings.json 의 공유 부분(훅 등록). 비밀 없음.
plugins-manifest.json      # 설치돼야 할 plugin 목록(소스만, 캐시 제외)
providers.list             # 설치돼야 할 provider CLI 목록 + 버전핀
nco/                       # nco / nova-ax 공유 config (코드는 각 repo, 여기엔 config만)
install/
  apply.sh          # pull→템플릿치환→백업→~/.claude 적용→provider점검 (dry-run 지원)
  fingerprint.sh    # read-only 환경 핑거프린트(드리프트 비교용, 비밀제외)
VERSION             # 정본 버전(= git short sha 로도 대체 가능)
```

## 동기화 규칙
- **canonical = claude-3 host.** 정본 변경은 claude-3가 push. 다른 머신은 read-only pull+apply.
- **제외**: inter-session 토큰, API키, OS전용(hwp/한글, /opt/homebrew vs WSL 경로 실값), per-machine `settings.local.json`.
- **템플릿**: 머신차 경로는 `{{HOME}}` `{{USER}}` `{{OS}}` 로 저장 → apply 시 치환.
- **전파**: 정본 push 시 NCO redis `config:update` 발행 또는 inter-session `--all` broadcast → 각 머신 apply.sh 실행.
