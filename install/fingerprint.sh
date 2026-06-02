#!/usr/bin/env bash
# read-only 환경 핑거프린트 (비밀 제외) — 드리프트 비교용
echo "host: $(hostname) os: $(uname -s)/$(uname -m)"
echo "claude: $(claude --version 2>/dev/null | head -1)"
echo "hooks: $(ls ~/.claude/hooks/*.sh 2>/dev/null | wc -l | tr -d ' ')"
echo "commands: $(ls ~/.claude/commands/*.md 2>/dev/null | wc -l | tr -d ' ')"
echo "skills: [$(ls ~/.claude/skills 2>/dev/null | tr '\n' ',' | sed 's/,$//')]"
echo "plugins: [$(ls ~/.claude/plugins/cache 2>/dev/null | tr '\n' ',' | sed 's/,$//')]"
echo "settings_hooks: $(python3 -c "import json;d=json.load(open('$HOME/.claude/settings.json'));print(sum(len(g.get('hooks',[])) for ev in d.get('hooks',{}).values() for g in ev))" 2>/dev/null)"
echo "providers: $(for p in claude codex gemini cursor-agent copilot opencode aider vllm higgsfield; do command -v $p >/dev/null 2>&1 && printf '%s ' $p; done)"
