# 제거된 MLX pm2 블록 (bootstrap.sh) — 2026-07-29

지휘자(claude-5) 정정 지시로 제거. 복원이 필요하면 이 블록을 bootstrap.sh 의
ecosystem 생성부(‘MLX 서버 설정’ 주석 자리)에 되돌리고, ECOSYSEOF 히어독 안의
`  ],` 앞줄에 `\${MLX_SERVER_BLOCK}` 참조를 복구하면 된다.

## 제거 근거 (실측 2026-07-29 14:3xZ)
- :8000 LISTEN 0줄, :7860 LISTEN 0줄, :4100 LISTEN 0줄, mlx 관련 프로세스 0건
- pm2 이름은 'mlx-server' 지만 args 의 모델이 gemma-4-26b-a4b-it-4bit = 채팅 모델. TTS 아님
- TTS 훅(~/.claude/hooks/nova-voice-tts.sh:35-40)이 쓰는 포트는 7861/7860/8800/8801. :8000 없음
- mlx-proxy 가 가리키는 $NCO_DIR/security-kb/anthropic-ollama-proxy.py 는 파일 자체가 부재 → 죽은 등록
- 2026-07-21 사용자 지시 'MLX 완전 제거' 범위

## 보존 대상 (제거하지 않음)
- ~/.local/bin/mlx_lm.server 바이너리
- nova-voice 의 .venv-tts (pip 설치 라이브러리)

## 원문
```bash
  # MLX 서버 설정 (Mac arm64만)
  MLX_SERVER_BLOCK=""
  if [[ "$OS" == "mac" && "$IS_ARM64" == "true" ]]; then
    MLX_BIN="$HOME/.local/bin/mlx_lm.server"
    MLX_MODEL="$HOME/project/LM-models/mlx/gemma-4-26b-a4b-it-4bit"
    MLX_SERVER_BLOCK=$(cat << MLXEOF
  {
    name: 'mlx-server',
    interpreter: 'none',
    script: '${MLX_BIN}',
    args: '--model ${MLX_MODEL} --port 8000 --host 127.0.0.1',
    cwd: '${NCO_DIR}',
    instances: 1,
    autorestart: true,
    watch: false,
    max_memory_restart: '30G',
    restart_delay: 10000,
    max_restarts: 20,
    min_uptime: '30s',
  },
  {
    name: 'mlx-proxy',
    script: '${NCO_DIR}/security-kb/anthropic-ollama-proxy.py',
    interpreter: 'python3',
    cwd: '${NCO_DIR}',
    instances: 1,
    autorestart: true,
    watch: false,
    restart_delay: 5000,
    max_restarts: 10,
    min_uptime: '15s',
  },
MLXEOF
)
```
