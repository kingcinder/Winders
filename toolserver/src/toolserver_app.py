from __future__ import annotations

import json
import os
import re
import subprocess
import time
from pathlib import Path
from typing import Any, Literal

from fastapi import FastAPI, Header, HTTPException, Request
from pydantic import BaseModel, Field


DEFAULT_CONFIG_PATH = r"C:\LocalLLM\config\toolserver-config.json"


def load_runtime_config() -> dict[str, Any]:
    config_path = os.environ.get("TOOLSERVER_CONFIG_PATH", DEFAULT_CONFIG_PATH)
    with open(config_path, "r", encoding="utf-8-sig") as handle:
        return json.load(handle)


RUNTIME_CONFIG = load_runtime_config()
SERVER_CONFIG = RUNTIME_CONFIG["server"]
SANDBOX_CONFIG = RUNTIME_CONFIG["sandbox"]

app = FastAPI(
    title=SERVER_CONFIG["name"],
    version="1.0.0",
    description=(
        "Locally hosted system-control tools for Open WebUI. "
        "Standard mode is the default and blocks destructive commands or writes outside writable roots. "
        "Override mode removes those protections when explicitly requested."
    ),
)


def now_utc() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def write_audit(entry: dict[str, Any]) -> None:
    path = Path(SERVER_CONFIG["audit_log_path"])
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(entry, ensure_ascii=True) + "\n")


def audit_payload(payload: Any) -> Any:
    if isinstance(payload, dict):
        result: dict[str, Any] = {}
        for key, value in payload.items():
            if key in {"content", "command"} and isinstance(value, str) and len(value) > 400:
                result[key] = value[:400] + "...<truncated>"
            else:
                result[key] = audit_payload(value)
        return result
    if isinstance(payload, list):
        return [audit_payload(item) for item in payload[:50]]
    if isinstance(payload, str) and len(payload) > 400:
        return payload[:400] + "...<truncated>"
    return payload


def resolve_path(path_value: str) -> Path:
    return Path(os.path.abspath(os.path.expandvars(path_value)))


WRITE_ROOTS = [resolve_path(path) for path in SANDBOX_CONFIG.get("write_roots", [])]
PROTECTED_ROOTS = [resolve_path(path) for path in SANDBOX_CONFIG.get("protected_roots", [])]
DESTRUCTIVE_PATTERNS = [re.compile(pattern) for pattern in SANDBOX_CONFIG.get("destructive_command_patterns", [])]


def is_within(candidate: Path, roots: list[Path]) -> bool:
    candidate_norm = str(candidate).lower()
    for root in roots:
        root_norm = str(root).lower().rstrip("\\/")
        if candidate_norm == root_norm or candidate_norm.startswith(root_norm + os.sep):
            return True
    return False


def effective_sandbox(requested: str | None) -> Literal["standard", "override"]:
    mode = (requested or SERVER_CONFIG.get("default_sandbox", "standard")).strip().lower()
    if mode not in {"standard", "override"}:
        raise HTTPException(status_code=400, detail=f"Unsupported sandbox mode '{mode}'.")
    if mode == "override" and not SERVER_CONFIG.get("override_enabled", False):
        raise HTTPException(status_code=403, detail="Override mode is disabled.")
    return mode  # type: ignore[return-value]


def enforce_write_path(path_value: str, mode: str) -> Path:
    path = resolve_path(path_value)
    if mode == "override":
        return path
    if is_within(path, PROTECTED_ROOTS):
        raise HTTPException(status_code=403, detail=f"Path '{path}' is protected in standard mode.")
    if not is_within(path, WRITE_ROOTS):
        raise HTTPException(status_code=403, detail=f"Path '{path}' is outside configured write roots in standard mode.")
    return path


def enforce_command(command: str, mode: str) -> None:
    if mode == "override":
        return
    for pattern in DESTRUCTIVE_PATTERNS:
        if pattern.search(command):
            raise HTTPException(status_code=403, detail=f"Command blocked in standard mode by pattern '{pattern.pattern}'.")


def require_auth(authorization: str | None) -> None:
    expected = SERVER_CONFIG.get("bearer_token", "")
    if not expected:
        return
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Missing bearer token.")
    provided = authorization.split(" ", 1)[1].strip()
    if provided != expected:
        raise HTTPException(status_code=403, detail="Invalid bearer token.")


@app.middleware("http")
async def auth_and_audit(request: Request, call_next):
    start = time.time()
    authorization = request.headers.get("Authorization")
    body_payload: Any = None

    if request.method in {"POST", "PUT", "PATCH", "DELETE"}:
        body_bytes = await request.body()
        if body_bytes:
            try:
                body_payload = json.loads(body_bytes)
            except Exception:
                body_payload = {"raw": body_bytes.decode("utf-8", errors="ignore")}

    try:
        if request.url.path != "/health":
            require_auth(authorization)
        response = await call_next(request)
        return response
    finally:
        write_audit(
            {
                "timestamp": now_utc(),
                "client": request.client.host if request.client else None,
                "method": request.method,
                "path": request.url.path,
                "query": dict(request.query_params),
                "body": audit_payload(body_payload),
                "duration_ms": int((time.time() - start) * 1000),
            }
        )


class CommandRequest(BaseModel):
    command: str = Field(..., description="PowerShell command text to execute.")
    cwd: str | None = Field(None, description="Optional working directory.")
    timeout_sec: int = Field(120, ge=1, le=1800)
    sandbox_mode: Literal["standard", "override"] | None = None


class ReadFileRequest(BaseModel):
    path: str
    encoding: str = "utf-8"
    max_chars: int = Field(200000, ge=1, le=1000000)


class WriteFileRequest(BaseModel):
    path: str
    content: str
    encoding: str = "utf-8"
    append: bool = False
    create_dirs: bool = True
    sandbox_mode: Literal["standard", "override"] | None = None


class ListDirectoryRequest(BaseModel):
    path: str
    recurse: bool = False
    max_entries: int = Field(500, ge=1, le=5000)


class SearchTextRequest(BaseModel):
    path: str
    pattern: str
    recurse: bool = True
    case_sensitive: bool = False
    max_matches: int = Field(200, ge=1, le=2000)


class StatPathRequest(BaseModel):
    path: str


class ListProcessesRequest(BaseModel):
    name_filter: str | None = None
    limit: int = Field(200, ge=1, le=2000)


class KillProcessRequest(BaseModel):
    pid: int = Field(..., ge=1)
    sandbox_mode: Literal["standard", "override"] | None = None


@app.get("/health", operation_id="get_health")
def get_health() -> dict[str, Any]:
    return {
        "ok": True,
        "service": SERVER_CONFIG["name"],
        "sandbox_default": SERVER_CONFIG.get("default_sandbox", "standard"),
        "override_enabled": SERVER_CONFIG.get("override_enabled", False),
    }


@app.post("/tools/execute_powershell", operation_id="execute_powershell")
def execute_powershell(request: CommandRequest) -> dict[str, Any]:
    mode = effective_sandbox(request.sandbox_mode)
    enforce_command(request.command, mode)

    cwd = resolve_path(request.cwd) if request.cwd else None
    if cwd and not cwd.exists():
        raise HTTPException(status_code=400, detail=f"Working directory '{cwd}' does not exist.")

    result = subprocess.run(
        [
            "powershell.exe",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            request.command,
        ],
        cwd=str(cwd) if cwd else None,
        capture_output=True,
        text=True,
        timeout=request.timeout_sec,
    )

    return {
        "sandbox_mode": mode,
        "exit_code": result.returncode,
        "stdout": result.stdout,
        "stderr": result.stderr,
        "cwd": str(cwd) if cwd else None,
    }


@app.post("/tools/read_file", operation_id="read_file")
def read_file(request: ReadFileRequest) -> dict[str, Any]:
    path = resolve_path(request.path)
    if not path.exists():
        raise HTTPException(status_code=404, detail=f"Path '{path}' does not exist.")
    if not path.is_file():
        raise HTTPException(status_code=400, detail=f"Path '{path}' is not a file.")

    content = path.read_text(encoding=request.encoding, errors="replace")
    if len(content) > request.max_chars:
        content = content[: request.max_chars] + "\n...<truncated>"

    return {
        "path": str(path),
        "size_bytes": path.stat().st_size,
        "content": content,
    }


@app.post("/tools/write_file", operation_id="write_file")
def write_file(request: WriteFileRequest) -> dict[str, Any]:
    mode = effective_sandbox(request.sandbox_mode)
    path = enforce_write_path(request.path, mode)
    if request.create_dirs:
        path.parent.mkdir(parents=True, exist_ok=True)
    write_mode = "a" if request.append else "w"
    with path.open(write_mode, encoding=request.encoding) as handle:
        handle.write(request.content)

    return {
        "path": str(path),
        "bytes_written": len(request.content.encode(request.encoding, errors="replace")),
        "append": request.append,
        "sandbox_mode": mode,
    }


@app.post("/tools/list_directory", operation_id="list_directory")
def list_directory(request: ListDirectoryRequest) -> dict[str, Any]:
    path = resolve_path(request.path)
    if not path.exists():
        raise HTTPException(status_code=404, detail=f"Path '{path}' does not exist.")
    if not path.is_dir():
        raise HTTPException(status_code=400, detail=f"Path '{path}' is not a directory.")

    entries: list[dict[str, Any]] = []
    if request.recurse:
        iterator = path.rglob("*")
    else:
        iterator = path.iterdir()

    for entry in iterator:
        try:
            stat = entry.stat()
        except OSError:
            continue
        entries.append(
            {
                "name": entry.name,
                "path": str(entry),
                "is_dir": entry.is_dir(),
                "size_bytes": stat.st_size,
                "modified_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(stat.st_mtime)),
            }
        )
        if len(entries) >= request.max_entries:
            break

    return {
        "path": str(path),
        "entries": entries,
        "truncated": len(entries) >= request.max_entries,
    }


@app.post("/tools/search_text", operation_id="search_text")
def search_text(request: SearchTextRequest) -> dict[str, Any]:
    path = resolve_path(request.path)
    if not path.exists():
        raise HTTPException(status_code=404, detail=f"Path '{path}' does not exist.")

    regex_flags = 0 if request.case_sensitive else re.IGNORECASE
    regex = re.compile(request.pattern, regex_flags)
    matches: list[dict[str, Any]] = []

    files = path.rglob("*") if path.is_dir() and request.recurse else (path.iterdir() if path.is_dir() else [path])
    for candidate in files:
        if not candidate.is_file():
            continue
        try:
            with candidate.open("r", encoding="utf-8", errors="ignore") as handle:
                for line_number, line in enumerate(handle, start=1):
                    if regex.search(line):
                        matches.append(
                            {
                                "path": str(candidate),
                                "line_number": line_number,
                                "line": line.rstrip(),
                            }
                        )
                        if len(matches) >= request.max_matches:
                            return {"matches": matches, "truncated": True}
        except OSError:
            continue

    return {"matches": matches, "truncated": False}


@app.post("/tools/stat_path", operation_id="stat_path")
def stat_path(request: StatPathRequest) -> dict[str, Any]:
    path = resolve_path(request.path)
    if not path.exists():
        raise HTTPException(status_code=404, detail=f"Path '{path}' does not exist.")
    stat = path.stat()
    return {
        "path": str(path),
        "exists": True,
        "is_file": path.is_file(),
        "is_dir": path.is_dir(),
        "size_bytes": stat.st_size,
        "modified_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(stat.st_mtime)),
    }


@app.post("/tools/list_processes", operation_id="list_processes")
def list_processes(request: ListProcessesRequest) -> dict[str, Any]:
    ps_script = (
        "Get-CimInstance Win32_Process | "
        "Select-Object ProcessId,Name,ExecutablePath,CommandLine | "
        "ConvertTo-Json -Depth 4"
    )
    result = subprocess.run(
        ["powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", ps_script],
        capture_output=True,
        text=True,
        timeout=120,
    )
    if result.returncode != 0:
        raise HTTPException(status_code=500, detail=result.stderr or "Failed to enumerate processes.")

    payload = json.loads(result.stdout) if result.stdout.strip() else []
    rows = payload if isinstance(payload, list) else [payload]
    filtered: list[dict[str, Any]] = []
    for row in rows:
        name = row.get("Name") or ""
        if request.name_filter and request.name_filter.lower() not in name.lower():
            continue
        filtered.append(
            {
                "pid": row.get("ProcessId"),
                "name": name,
                "executable_path": row.get("ExecutablePath"),
                "command_line": row.get("CommandLine"),
            }
        )
        if len(filtered) >= request.limit:
            break

    return {"processes": filtered, "truncated": len(filtered) >= request.limit}


@app.post("/tools/kill_process", operation_id="kill_process")
def kill_process(request: KillProcessRequest) -> dict[str, Any]:
    mode = effective_sandbox(request.sandbox_mode)
    if mode != "override":
        raise HTTPException(status_code=403, detail="kill_process requires override mode.")

    result = subprocess.run(
        ["taskkill.exe", "/PID", str(request.pid), "/T", "/F"],
        capture_output=True,
        text=True,
        timeout=60,
    )
    return {
        "sandbox_mode": mode,
        "exit_code": result.returncode,
        "stdout": result.stdout,
        "stderr": result.stderr,
    }
