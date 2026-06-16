#!/usr/bin/env python3
"""
provider-tools MCP Server — 모든 AI 프로바이더 도구를 MCP로 노출
stdio JSON-RPC 2.0 transport (Claude Code 호환)
"""
import json
import sys
import os
import subprocess
import threading
from typing import Any

REGISTRY_PATH = os.path.expanduser("~/.claude/provider-tools/registry.json")
DISPATCH_PATH = os.path.expanduser("~/.claude/provider-tools/provider-run.sh")
NCO_API = "http://localhost:6200"

def load_registry() -> dict:
    try:
        with open(REGISTRY_PATH) as f:
            return json.load(f)
    except Exception:
        return {"providers": {}}

def build_tools() -> list:
    """레지스트리에서 MCP 도구 목록 동적 생성"""
    reg = load_registry()
    tools = []

    # ── 메타 도구 ──────────────────────────────────────────
    tools.append({
        "name": "provider_list",
        "description": "설치된 모든 AI 프로바이더 목록과 각 프로바이더의 사용 가능한 도구를 반환합니다.",
        "inputSchema": {
            "type": "object",
            "properties": {},
            "required": []
        }
    })

    tools.append({
        "name": "provider_info",
        "description": "특정 AI 프로바이더의 상세 정보와 도구 사용법을 반환합니다.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "provider": {
                    "type": "string",
                    "description": "프로바이더 ID (예: codex, gemini, hermes, mlx)"
                }
            },
            "required": ["provider"]
        }
    })

    tools.append({
        "name": "provider_run",
        "description": "지정한 AI 프로바이더의 특정 도구를 실행합니다. provider_list로 프로바이더/도구 목록을 먼저 확인하세요.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "ai": {
                    "type": "string",
                    "description": "프로바이더 ID (codex, opencode, gemini, cursor-agent, hermes, copilot, aider, mlx, nvidia, gemini-deep, openrouter, higgsfield, openclaw)"
                },
                "tool": {
                    "type": "string",
                    "description": "실행할 도구명 (예: exec, prompt, oneshot, run, generate)"
                },
                "prompt": {
                    "type": "string",
                    "description": "AI에게 전달할 프롬프트/지시"
                },
                "extra_args": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "추가 CLI 인수 (선택)",
                    "default": []
                }
            },
            "required": ["ai", "tool", "prompt"]
        }
    })

    tools.append({
        "name": "nco_task",
        "description": "NCO 백엔드를 통해 AI 에이전트에게 태스크를 위임합니다. NCO가 온라인일 때 사용.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "ai": {
                    "type": "string",
                    "description": "에이전트 ID (opencode, codex, gemini, cursor-agent, copilot, openrouter, mlx, nvidia, higgsfield, gemini-deep, hermes, openclaw)"
                },
                "prompt": {
                    "type": "string",
                    "description": "태스크 지시"
                }
            },
            "required": ["ai", "prompt"]
        }
    })

    tools.append({
        "name": "nco_parallel",
        "description": "여러 AI 에이전트에게 동일한 태스크를 병렬로 실행합니다.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "prompt": {"type": "string", "description": "태스크 지시"},
                "providers": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "병렬 실행할 에이전트 목록 (예: [\"codex\", \"cursor-agent\"])"
                }
            },
            "required": ["prompt", "providers"]
        }
    })

    # ── 프로바이더별 개별 도구 ─────────────────────────────
    for pid, pdata in reg["providers"].items():
        for tname, tdata in pdata.get("tools", {}).items():
            tool_id = f"{pid.replace('-', '_')}_{tname}"
            tools.append({
                "name": tool_id,
                "description": f"[{pid}] {tdata.get('desc', '')} | 예: {tdata.get('example', '')}",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "prompt": {
                            "type": "string",
                            "description": "프롬프트/지시 내용"
                        },
                        "extra_args": {
                            "type": "array",
                            "items": {"type": "string"},
                            "description": "추가 옵션",
                            "default": []
                        }
                    },
                    "required": ["prompt"] if tname not in ("tools_list", "memory_list", "models", "kanban", "mcp_list", "skills_list", "cron_list") else []
                }
            })

    return tools

def execute_tool(name: str, args: dict) -> str:
    """도구 실행 및 결과 반환"""
    reg = load_registry()

    # ── 메타 도구 ──────────────────────────────────────────
    if name == "provider_list":
        lines = ["# AI 프로바이더 목록\n"]
        lines.append(f"{'ID':18} {'ROLE':16} {'SCORE':5}  도구 목록")
        lines.append("-" * 70)
        for pid, p in reg["providers"].items():
            tools = ", ".join(p.get("tools", {}).keys())
            via = " (via NCO)" if p.get("via_nco") else ""
            lines.append(f"{pid:18} {p.get('role','?'):16} {str(p.get('score','?')):5}  {tools}{via}")
        lines.append("\nNCO API: POST http://localhost:6200/api/task  {ai, prompt}")
        return "\n".join(lines)

    if name == "provider_info":
        pid = args.get("provider", "")
        p = reg["providers"].get(pid)
        if not p:
            return f"❌ 프로바이더 '{pid}' 없음. provider_list로 목록 확인"
        lines = [f"# {p['name']} [{pid}]"]
        lines.append(f"Role: {p.get('role')} | Score: {p.get('score')} | Type: {p.get('type')}")
        if p.get("binary"): lines.append(f"Binary: {p['binary']}")
        if p.get("via_nco"): lines.append("⚡ NCO 경유 실행")
        lines.append("\n## 도구")
        for tname, t in p.get("tools", {}).items():
            lines.append(f"\n### {tname}")
            lines.append(f"설명: {t.get('desc', '')}")
            if t.get("options"):
                lines.append("옵션:")
                for opt, desc in t["options"].items():
                    lines.append(f"  {opt}  # {desc}")
            lines.append(f"예시: {t.get('example', '')}")
        return "\n".join(lines)

    if name == "provider_run":
        ai = args.get("ai", "")
        tool = args.get("tool", "")
        prompt = args.get("prompt", "")
        extra = args.get("extra_args", [])
        cmd = ["/bin/bash", DISPATCH_PATH, "--ai", ai, "--tool", tool, "--prompt", prompt] + extra
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
            output = result.stdout + (f"\n[stderr]: {result.stderr}" if result.stderr.strip() else "")
            return output or "(출력 없음)"
        except subprocess.TimeoutExpired:
            return "⏱️ 시간 초과 (120s). 백그라운드 실행을 고려하세요."
        except Exception as e:
            return f"❌ 실행 실패: {e}"

    if name == "nco_task":
        ai = args.get("ai", "")
        prompt = args.get("prompt", "")
        try:
            payload = json.dumps({"ai": ai, "prompt": prompt})
            result = subprocess.run(
                ["curl", "-s", "-X", "POST", f"{NCO_API}/api/task",
                 "-H", "Content-Type: application/json", "-d", payload],
                capture_output=True, text=True, timeout=180
            )
            return result.stdout or "(응답 없음)"
        except Exception as e:
            return f"❌ NCO 실행 실패: {e}"

    if name == "nco_parallel":
        prompt = args.get("prompt", "")
        providers = args.get("providers", [])
        try:
            payload = json.dumps({"prompt": prompt, "providers": providers})
            result = subprocess.run(
                ["curl", "-s", "-X", "POST", f"{NCO_API}/api/parallel",
                 "-H", "Content-Type: application/json", "-d", payload],
                capture_output=True, text=True, timeout=300
            )
            return result.stdout or "(응답 없음)"
        except Exception as e:
            return f"❌ NCO 병렬 실행 실패: {e}"

    # ── 개별 프로바이더 도구 (codex_exec, gemini_prompt 등) ───
    # tool_id = {pid}_{tname} → pid: 원래 ID (언더스코어→하이픈 복원)
    for pid, pdata in reg["providers"].items():
        pid_norm = pid.replace("-", "_")
        for tname in pdata.get("tools", {}).keys():
            expected = f"{pid_norm}_{tname}"
            if name == expected:
                prompt = args.get("prompt", "")
                extra = args.get("extra_args", [])
                cmd = ["/bin/bash", DISPATCH_PATH, "--ai", pid, "--tool", tname, "--prompt", prompt] + extra
                try:
                    result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
                    output = result.stdout + (f"\n[stderr]: {result.stderr}" if result.stderr.strip() else "")
                    return output or "(출력 없음)"
                except subprocess.TimeoutExpired:
                    return "⏱️ 시간 초과 (120s)"
                except Exception as e:
                    return f"❌ {pid}/{tname} 실행 실패: {e}"

    return f"❌ 알 수 없는 도구: {name}"


# ── MCP 서버 메인 루프 ─────────────────────────────────────
def send_response(response: dict):
    line = json.dumps(response, ensure_ascii=False)
    sys.stdout.write(line + "\n")
    sys.stdout.flush()

def handle_request(req: dict):
    method = req.get("method", "")
    req_id = req.get("id")

    if method == "initialize":
        send_response({
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "provider-tools", "version": "1.0.0"}
            }
        })

    elif method == "notifications/initialized":
        pass  # no response needed

    elif method == "tools/list":
        tools = build_tools()
        send_response({
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {"tools": tools}
        })

    elif method == "tools/call":
        params = req.get("params", {})
        tool_name = params.get("name", "")
        tool_args = params.get("arguments", {})

        try:
            result_text = execute_tool(tool_name, tool_args)
        except Exception as e:
            result_text = f"❌ 도구 실행 오류: {e}"

        send_response({
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "content": [{"type": "text", "text": result_text}],
                "isError": result_text.startswith("❌")
            }
        })

    elif method == "ping":
        send_response({"jsonrpc": "2.0", "id": req_id, "result": {}})

    elif req_id is not None:
        send_response({
            "jsonrpc": "2.0",
            "id": req_id,
            "error": {"code": -32601, "message": f"Method not found: {method}"}
        })

def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            continue
        try:
            handle_request(req)
        except Exception as e:
            req_id = req.get("id") if isinstance(req, dict) else None
            if req_id is not None:
                send_response({
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "error": {"code": -32603, "message": str(e)}
                })

if __name__ == "__main__":
    main()
