from __future__ import annotations

import json
import os
import posixpath
import re
import shlex
import shutil
import socket
import subprocess
import time
from pathlib import Path
from typing import Any, Literal

from fastapi import FastAPI, Header, HTTPException, Request
import paramiko
from pydantic import BaseModel, Field


DEFAULT_CONFIG_PATH = r"C:\LocalLLM\config\toolserver-config.json"


def load_runtime_config() -> dict[str, Any]:
    config_path = os.environ.get("TOOLSERVER_CONFIG_PATH", DEFAULT_CONFIG_PATH)
    with open(config_path, "r", encoding="utf-8-sig") as handle:
        return json.load(handle)


RUNTIME_CONFIG = load_runtime_config()
SERVER_CONFIG = RUNTIME_CONFIG["server"]
SANDBOX_CONFIG = RUNTIME_CONFIG["sandbox"]
LINUX_VM_CONFIG = RUNTIME_CONFIG.get("linux_vm", {})

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


def run_local_command(args: list[str], timeout: int = 60) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout)


def find_vboxmanage() -> str:
    candidates = [
        shutil.which("VBoxManage.exe"),
        shutil.which("VBoxManage"),
        r"C:\Program Files\Oracle\VirtualBox\VBoxManage.exe",
    ]
    for candidate in candidates:
        if candidate and Path(candidate).exists():
            return candidate
    raise HTTPException(status_code=500, detail="VBoxManage.exe not found on host.")


def get_linux_vm_name(vm_name: str | None = None) -> str:
    name = (vm_name or LINUX_VM_CONFIG.get("virtualbox_vm_name") or "").strip()
    if not name:
        raise HTTPException(status_code=400, detail="Linux VM name is not configured.")
    return name


def get_virtualbox_showvminfo(vm_name: str | None = None) -> dict[str, str]:
    vboxmanage = find_vboxmanage()
    result = run_local_command([vboxmanage, "showvminfo", get_linux_vm_name(vm_name), "--machinereadable"], timeout=60)
    if result.returncode != 0:
        raise HTTPException(status_code=500, detail=result.stderr.strip() or result.stdout.strip() or "VBoxManage showvminfo failed.")

    data: dict[str, str] = {}
    for line in result.stdout.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        data[key] = value.strip().strip('"')
    return data


def get_virtualbox_guestproperties(vm_name: str | None = None) -> dict[str, str]:
    vboxmanage = find_vboxmanage()
    result = run_local_command([vboxmanage, "guestproperty", "enumerate", get_linux_vm_name(vm_name)], timeout=60)
    if result.returncode != 0:
        raise HTTPException(status_code=500, detail=result.stderr.strip() or result.stdout.strip() or "VBoxManage guestproperty enumerate failed.")

    properties: dict[str, str] = {}
    for line in result.stdout.splitlines():
        if "=" not in line:
            continue
        key, remainder = line.split("=", 1)
        key = key.strip()
        value = remainder.split("@", 1)[0].strip().strip("'")
        properties[key] = value
    return properties


def get_linux_vm_status_payload(vm_name: str | None = None) -> dict[str, Any]:
    name = get_linux_vm_name(vm_name)
    info = get_virtualbox_showvminfo(name)
    properties = get_virtualbox_guestproperties(name)
    return {
        "provider": "virtualbox",
        "vm_name": name,
        "state": info.get("VMState"),
        "session_name": info.get("SessionName"),
        "ssh_host": LINUX_VM_CONFIG.get("ssh_host"),
        "ssh_port": int(LINUX_VM_CONFIG.get("ssh_port", 22)),
        "nat_rule_name": LINUX_VM_CONFIG.get("nat_rule_name"),
        "nat_forwarding": [value for key, value in info.items() if key.startswith("Forwarding(")],
        "guest_ipv4": properties.get("/VirtualBox/GuestInfo/Net/0/V4/IP"),
        "guest_user_detected": properties.get("/VirtualBox/GuestInfo/OS/LoggedInUsersList") or LINUX_VM_CONFIG.get("detected_user"),
        "guest_os": properties.get("/VirtualBox/GuestInfo/OS/Product"),
        "guest_release": properties.get("/VirtualBox/GuestInfo/OS/Release"),
        "guest_version": properties.get("/VirtualBox/GuestInfo/OS/Version"),
    }


def ensure_virtualbox_nat_ssh_forward_impl(vm_name: str | None = None) -> dict[str, Any]:
    name = get_linux_vm_name(vm_name)
    info = get_virtualbox_showvminfo(name)
    vboxmanage = find_vboxmanage()
    ssh_host = str(LINUX_VM_CONFIG.get("ssh_host", "127.0.0.1"))
    ssh_port = str(int(LINUX_VM_CONFIG.get("ssh_port", 2222)))
    rule_name = str(LINUX_VM_CONFIG.get("nat_rule_name", "localllm-ssh"))
    rule_value = f"{rule_name},tcp,{ssh_host},{ssh_port},,22"

    if any(value == rule_value for key, value in info.items() if key.startswith("Forwarding(")):
        return {
            "vm_name": name,
            "already_present": True,
            "rule": rule_value,
        }

    delete_args = [vboxmanage, "controlvm" if info.get("VMState") == "running" else "modifyvm", name, "natpf1"]
    create_args = [vboxmanage, "controlvm" if info.get("VMState") == "running" else "modifyvm", name, "natpf1", rule_value]

    run_local_command(delete_args + ["delete", rule_name], timeout=30)
    result = run_local_command(create_args, timeout=60)
    if result.returncode != 0:
        raise HTTPException(status_code=500, detail=result.stderr.strip() or result.stdout.strip() or "Failed to configure NAT SSH forwarding.")

    return {
        "vm_name": name,
        "already_present": False,
        "rule": rule_value,
    }


def test_tcp_connect(host: str, port: int, timeout: int = 5) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def get_linux_vm_auth() -> tuple[str, dict[str, Any]]:
    username = (LINUX_VM_CONFIG.get("ssh_user") or "").strip()
    password = LINUX_VM_CONFIG.get("ssh_password") or ""
    private_key_path = (LINUX_VM_CONFIG.get("ssh_private_key_path") or "").strip()

    if not username:
        raise HTTPException(status_code=400, detail="Linux VM SSH username is not configured.")

    auth_kwargs: dict[str, Any] = {
        "username": username,
        "look_for_keys": False,
        "allow_agent": False,
        "timeout": 15,
        "banner_timeout": 15,
        "auth_timeout": 15,
    }

    if private_key_path:
        key_path = Path(os.path.expandvars(private_key_path))
        if not key_path.exists():
            raise HTTPException(status_code=400, detail=f"Linux VM SSH private key path '{key_path}' does not exist.")
        auth_kwargs["key_filename"] = str(key_path)
    elif password:
        auth_kwargs["password"] = password
    else:
        raise HTTPException(status_code=400, detail="Linux VM SSH credentials are not configured. Set a password or private key path in toolserver-config.json.")

    return username, auth_kwargs


def connect_linux_vm() -> paramiko.SSHClient:
    host = str(LINUX_VM_CONFIG.get("ssh_host", "127.0.0.1"))
    port = int(LINUX_VM_CONFIG.get("ssh_port", 2222))
    _, auth_kwargs = get_linux_vm_auth()

    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        client.connect(hostname=host, port=port, **auth_kwargs)
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"Failed to connect to Linux VM over SSH: {exc}") from exc
    return client


def ensure_safe_target_value(value: str, field_name: str) -> str:
    normalized = (value or "").strip()
    if not normalized:
        raise HTTPException(status_code=400, detail=f"{field_name} must be non-empty.")
    if any(ch in normalized for ch in ("\r", "\n", "\x00")):
        raise HTTPException(status_code=400, detail=f"{field_name} contains invalid control characters.")
    return normalized


def ensure_linux_file_exists(path_value: str, field_name: str) -> str:
    normalized = ensure_safe_target_value(path_value, field_name)
    result = run_linux_command(["test", "-f", normalized], timeout_sec=15)
    if result["exit_code"] != 0:
        raise HTTPException(status_code=400, detail=f"{field_name} '{normalized}' does not exist in the Kali VM.")
    return normalized


def ensure_linux_directory(path_value: str, field_name: str) -> str:
    normalized = ensure_safe_target_value(path_value, field_name)
    result = run_linux_command(["mkdir", "-p", normalized], timeout_sec=15, require_zero_exit=True)
    return normalized


def build_linux_artifact_path(prefix: str, extension: str) -> str:
    artifact_dir = ensure_linux_directory("/tmp/localllm-artifacts", "artifact_dir")
    timestamp = int(time.time())
    return posixpath.join(artifact_dir, f"{prefix}-{timestamp}{extension}")


def run_linux_command(
    argv: list[str],
    timeout_sec: int = 120,
    cwd: str | None = None,
    require_zero_exit: bool = False,
) -> dict[str, Any]:
    client = connect_linux_vm()
    try:
        command_line = " ".join(shlex.quote(arg) for arg in argv)
        wrapped_command = command_line if not cwd else f"cd {shlex.quote(cwd)} && {command_line}"
        stdin, stdout, stderr = client.exec_command(wrapped_command, timeout=timeout_sec)
        stdin.close()
        stdout.channel.shutdown_write()
        stdout_text = stdout.read().decode("utf-8", errors="replace")
        stderr_text = stderr.read().decode("utf-8", errors="replace")
        exit_code = stdout.channel.recv_exit_status()
        if require_zero_exit and exit_code != 0:
            raise HTTPException(
                status_code=500,
                detail={
                    "command": wrapped_command,
                    "exit_code": exit_code,
                    "stdout": stdout_text,
                    "stderr": stderr_text,
                },
            )
        return {
            "command": wrapped_command,
            "exit_code": exit_code,
            "stdout": stdout_text,
            "stderr": stderr_text,
        }
    finally:
        client.close()


def resolve_linux_tool_command(tool_name: str) -> str:
    result = run_linux_command(["command", "-v", tool_name], timeout_sec=15)
    if result["exit_code"] != 0 or not result["stdout"].strip():
        raise HTTPException(status_code=404, detail=f"Kali tool '{tool_name}' is not installed in the VM.")
    return result["stdout"].splitlines()[0].strip()


def assert_linux_tool_installed(tool_name: str) -> str:
    return resolve_linux_tool_command(tool_name)


def get_effective_linux_tool_command(tool_name: str) -> str:
    command_path = resolve_linux_tool_command(tool_name)
    if tool_name == "amass":
        real_path = "/usr/lib/amass/amass"
        probe = run_linux_command(["test", "-x", real_path], timeout_sec=15)
        if probe["exit_code"] == 0:
            return real_path
    return command_path


def build_smbclient_auth_args(
    username: str | None,
    password: str | None,
    workgroup: str | None,
) -> list[str]:
    argv: list[str] = []
    if workgroup:
        argv.extend(["-W", ensure_safe_target_value(workgroup, "workgroup")])
    if username:
        username_value = ensure_safe_target_value(username, "username")
        if password is not None:
            argv.extend(["-U", f"{username_value}%{password}"])
        else:
            argv.extend(["-U", username_value, "-N"])
    else:
        argv.append("-N")
    return argv


KALI_WRAPPER_DEFINITIONS: list[dict[str, str]] = [
    {"operation_id": "kali_run_whois", "tool": "whois", "purpose": "WHOIS and registration data lookup for a domain or IP."},
    {"operation_id": "kali_run_dig", "tool": "dig", "purpose": "DNS record lookup for a name and record type."},
    {"operation_id": "kali_run_host", "tool": "host", "purpose": "DNS lookup using the host CLI."},
    {"operation_id": "kali_run_nslookup", "tool": "nslookup", "purpose": "DNS lookup using the nslookup CLI."},
    {"operation_id": "kali_run_curl", "tool": "curl", "purpose": "HTTP fetch with explicit method, redirect, and TLS verification options."},
    {"operation_id": "kali_run_wget", "tool": "wget", "purpose": "HTTP fetch using wget with spider and redirect controls."},
    {"operation_id": "kali_run_whatweb", "tool": "whatweb", "purpose": "Web stack fingerprinting and technology detection."},
    {"operation_id": "kali_run_wafw00f", "tool": "wafw00f", "purpose": "WAF detection against a specific URL."},
    {"operation_id": "kali_run_nikto", "tool": "nikto", "purpose": "Web server misconfiguration and known issue scan."},
    {"operation_id": "kali_run_wapiti", "tool": "wapiti", "purpose": "Web application assessment crawler and vuln checks."},
    {"operation_id": "kali_run_nmap", "tool": "nmap", "purpose": "Host and service enumeration with bounded options."},
    {"operation_id": "kali_run_traceroute", "tool": "traceroute", "purpose": "Route tracing with bounded hops and probe counts."},
    {"operation_id": "kali_run_fping", "tool": "fping", "purpose": "Reachability probe for one or more hosts."},
    {"operation_id": "kali_run_arp_scan", "tool": "arp-scan", "purpose": "Local network ARP discovery with bounded scope."},
    {"operation_id": "kali_run_netcat_probe", "tool": "nc", "purpose": "TCP or UDP connectivity probe using netcat zero-I/O mode."},
    {"operation_id": "kali_run_tcpdump_capture", "tool": "tcpdump", "purpose": "Bounded packet capture to a pcap file."},
    {"operation_id": "kali_run_tshark_summary", "tool": "tshark", "purpose": "Packet summary view for a pcap artifact."},
    {"operation_id": "kali_run_tshark_protocol_hierarchy", "tool": "tshark", "purpose": "Protocol hierarchy statistics for a pcap artifact."},
    {"operation_id": "kali_run_tshark_conversations", "tool": "tshark", "purpose": "Conversation statistics for a pcap artifact."},
    {"operation_id": "kali_run_tshark_fields", "tool": "tshark", "purpose": "Field extraction from a pcap artifact."},
    {"operation_id": "kali_run_sslscan", "tool": "sslscan", "purpose": "TLS cipher and certificate inspection."},
    {"operation_id": "kali_run_sslyze", "tool": "sslyze", "purpose": "TLS and HTTP header analysis using SSLyze."},
    {"operation_id": "kali_run_openssl_s_client", "tool": "openssl", "purpose": "TLS handshake inspection using openssl s_client."},
    {"operation_id": "kali_run_httpx", "tool": "httpx", "purpose": "HTTPX client request wrapper for the Kali-installed CLI variant."},
    {"operation_id": "kali_run_dnsenum", "tool": "dnsenum", "purpose": "Domain DNS enumeration."},
    {"operation_id": "kali_run_dnsrecon", "tool": "dnsrecon", "purpose": "DNS reconnaissance for a domain."},
    {"operation_id": "kali_run_enum4linux_basic", "tool": "enum4linux", "purpose": "Basic SMB enumeration using enum4linux."},
    {"operation_id": "kali_run_smbclient_list_shares", "tool": "smbclient", "purpose": "List SMB shares on a specific host and port."},
    {"operation_id": "kali_run_smbclient_list_path", "tool": "smbclient", "purpose": "List contents of a specific SMB share path."},
    {"operation_id": "kali_run_smbclient_get_file", "tool": "smbclient", "purpose": "Retrieve a file from an SMB share into a local artifact path."},
    {"operation_id": "kali_run_gobuster_dir", "tool": "gobuster", "purpose": "Directory brute-force against a specific base URL."},
    {"operation_id": "kali_run_amass_passive", "tool": "amass", "purpose": "Passive subdomain enumeration."},
]


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


class VirtualBoxVmRequest(BaseModel):
    vm_name: str | None = None


class LinuxVmShellRequest(BaseModel):
    command: str
    timeout_sec: int = Field(120, ge=1, le=1800)
    cwd: str | None = None


class LinuxVmPathRequest(BaseModel):
    path: str
    max_chars: int = Field(200000, ge=1, le=1000000)


class LinuxVmWriteFileRequest(BaseModel):
    path: str
    content: str
    append: bool = False


class LinuxVmListDirectoryRequest(BaseModel):
    path: str
    max_entries: int = Field(500, ge=1, le=5000)


class LinuxVmListProcessesRequest(BaseModel):
    name_filter: str | None = None
    limit: int = Field(200, ge=1, le=2000)


class KaliWhoisRequest(BaseModel):
    query: str
    timeout_sec: int = Field(120, ge=1, le=1800)


class KaliDigRequest(BaseModel):
    name: str
    record_type: str = "A"
    dns_server: str | None = None
    short: bool = False
    timeout_sec: int = Field(60, ge=1, le=600)


class KaliHostRequest(BaseModel):
    name: str
    record_type: str = "A"
    dns_server: str | None = None
    timeout_sec: int = Field(60, ge=1, le=600)


class KaliNslookupRequest(BaseModel):
    name: str
    query_type: str = "A"
    dns_server: str | None = None
    timeout_sec: int = Field(60, ge=1, le=600)


class KaliCurlRequest(BaseModel):
    url: str
    method: Literal["GET", "HEAD"] = "GET"
    include_headers: bool = True
    follow_redirects: bool = True
    verify_tls: bool = True
    timeout_sec: int = Field(60, ge=1, le=600)


class KaliWgetRequest(BaseModel):
    url: str
    spider: bool = True
    server_response: bool = True
    follow_redirects: bool = True
    verify_tls: bool = True
    timeout_sec: int = Field(60, ge=1, le=600)


class KaliWhatwebRequest(BaseModel):
    url: str
    aggression: int = Field(1, ge=1, le=4)
    timeout_sec: int = Field(120, ge=1, le=1800)


class KaliWafw00fRequest(BaseModel):
    url: str
    find_all: bool = False
    no_redirect: bool = False
    timeout_sec: int = Field(120, ge=1, le=1800)


class KaliNiktoRequest(BaseModel):
    target_url: str
    timeout_sec: int = Field(300, ge=1, le=3600)


class KaliWapitiRequest(BaseModel):
    target_url: str
    scope: Literal["page", "folder", "domain", "url"] = "domain"
    modules: str = "all,-ssrf"
    timeout_sec: int = Field(600, ge=1, le=7200)


class KaliNmapRequest(BaseModel):
    target: str
    ports: str | None = None
    top_ports: int | None = Field(None, ge=1, le=1000)
    service_version: bool = True
    default_scripts: bool = False
    timeout_sec: int = Field(300, ge=1, le=3600)


class KaliTracerouteRequest(BaseModel):
    host: str
    method: Literal["udp", "tcp", "icmp"] = "udp"
    max_hops: int = Field(10, ge=1, le=64)
    queries: int = Field(1, ge=1, le=5)
    port: int | None = Field(None, ge=1, le=65535)
    numeric: bool = True
    timeout_sec: int = Field(120, ge=1, le=1800)


class KaliFpingRequest(BaseModel):
    targets: list[str]
    count: int = Field(1, ge=1, le=10)
    timeout_ms: int = Field(500, ge=50, le=10000)
    show_alive: bool = False
    timeout_sec: int = Field(60, ge=1, le=600)


class KaliArpScanRequest(BaseModel):
    targets: list[str] = Field(default_factory=list)
    interface: str | None = None
    localnet: bool = True
    plain: bool = True
    timeout_sec: int = Field(120, ge=1, le=1800)


class KaliNetcatProbeRequest(BaseModel):
    host: str
    port: int = Field(..., ge=1, le=65535)
    udp: bool = False
    timeout_sec: int = Field(10, ge=1, le=120)
    verbose: bool = True


class KaliTcpdumpCaptureRequest(BaseModel):
    interface: str
    capture_filter: str | None = None
    output_path: str | None = None
    packet_count: int | None = Field(None, ge=1, le=10000)
    duration_sec: int | None = Field(5, ge=1, le=600)
    snapshot_length: int = Field(256, ge=64, le=65535)
    no_promiscuous: bool = True
    timeout_sec: int = Field(120, ge=1, le=1800)


class KaliTsharkSummaryRequest(BaseModel):
    pcap_path: str
    max_packets: int = Field(20, ge=1, le=500)
    display_filter: str | None = None
    timeout_sec: int = Field(120, ge=1, le=1800)


class KaliTsharkProtocolHierarchyRequest(BaseModel):
    pcap_path: str
    display_filter: str | None = None
    timeout_sec: int = Field(120, ge=1, le=1800)


class KaliTsharkConversationsRequest(BaseModel):
    pcap_path: str
    conversation_type: Literal["tcp", "udp", "ip", "eth"] = "tcp"
    display_filter: str | None = None
    timeout_sec: int = Field(120, ge=1, le=1800)


class KaliTsharkFieldsRequest(BaseModel):
    pcap_path: str
    fields: list[str]
    max_packets: int = Field(20, ge=1, le=500)
    display_filter: str | None = None
    separator: Literal["tab", "comma", "space"] = "tab"
    include_header: bool = True
    timeout_sec: int = Field(120, ge=1, le=1800)


class KaliSslscanRequest(BaseModel):
    host: str
    port: int = Field(443, ge=1, le=65535)
    timeout_sec: int = Field(180, ge=1, le=1800)


class KaliSslyzeRequest(BaseModel):
    target: str
    sni: str | None = None
    certinfo: bool = True
    http_headers: bool = True
    tlsv1_2: bool = True
    tlsv1_3: bool = True
    mozilla_config: Literal["modern", "intermediate", "old", "disable"] = "disable"
    timeout_sec: int = Field(240, ge=1, le=1800)


class KaliOpenSslSClientRequest(BaseModel):
    host: str
    port: int = Field(443, ge=1, le=65535)
    servername: str | None = None
    tls_version: Literal["auto", "tls1", "tls1_1", "tls1_2", "tls1_3"] = "auto"
    show_certs: bool = True
    brief: bool = True
    timeout_sec: int = Field(120, ge=1, le=600)


class KaliHttpxRequest(BaseModel):
    url: str
    method: Literal["GET", "HEAD"] = "GET"
    follow_redirects: bool = True
    verify_tls: bool = True
    verbose: bool = False
    timeout_sec: int = Field(180, ge=1, le=1800)


class KaliDomainRequest(BaseModel):
    domain: str
    timeout_sec: int = Field(300, ge=1, le=3600)


class KaliSmbclientAuthRequest(BaseModel):
    host: str
    port: int = Field(445, ge=1, le=65535)
    username: str | None = None
    password: str | None = None
    workgroup: str | None = None
    timeout_sec: int = Field(60, ge=1, le=600)


class KaliSmbclientListPathRequest(KaliSmbclientAuthRequest):
    share: str
    remote_path: str = "."


class KaliSmbclientGetFileRequest(KaliSmbclientAuthRequest):
    share: str
    remote_path: str
    local_output_path: str | None = None


class KaliEnum4linuxBasicRequest(BaseModel):
    host: str
    username: str | None = None
    password: str | None = None
    users: bool = False
    shares: bool = True
    groups: bool = False
    password_policy: bool = True
    os_info: bool = False
    rid_cycle: bool = False
    timeout_sec: int = Field(180, ge=1, le=1800)


class KaliGobusterDirRequest(BaseModel):
    base_url: str
    wordlist_path: str = "/usr/share/wordlists/dirb/common.txt"
    extensions: list[str] = Field(default_factory=list)
    threads: int = Field(10, ge=1, le=50)
    timeout_sec: int = Field(600, ge=1, le=7200)


@app.get("/health", operation_id="get_health")
def get_health() -> dict[str, Any]:
    return {
        "ok": True,
        "service": SERVER_CONFIG["name"],
        "sandbox_default": SERVER_CONFIG.get("default_sandbox", "standard"),
        "override_enabled": SERVER_CONFIG.get("override_enabled", False),
        "linux_vm_enabled": LINUX_VM_CONFIG.get("enabled", False),
        "linux_vm_provider": LINUX_VM_CONFIG.get("provider"),
    }


@app.post("/tools/list_kali_wrappers", operation_id="list_kali_wrappers")
def list_kali_wrappers() -> dict[str, Any]:
    wrappers = []
    for definition in KALI_WRAPPER_DEFINITIONS:
        installed = False
        command_path = None
        try:
            command_path = get_effective_linux_tool_command(definition["tool"])
            installed = True
        except HTTPException:
            installed = False
        wrappers.append(
            {
                "operation_id": definition["operation_id"],
                "tool": definition["tool"],
                "purpose": definition["purpose"],
                "installed": installed,
                "command_path": command_path,
            }
        )
    return {"wrappers": wrappers}


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


@app.post("/tools/list_virtualbox_vms", operation_id="list_virtualbox_vms")
def list_virtualbox_vms() -> dict[str, Any]:
    vboxmanage = find_vboxmanage()
    result = run_local_command([vboxmanage, "list", "vms"], timeout=30)
    if result.returncode != 0:
        raise HTTPException(status_code=500, detail=result.stderr.strip() or "VBoxManage list vms failed.")
    running = run_local_command([vboxmanage, "list", "runningvms"], timeout=30)
    running_names = set()
    for line in running.stdout.splitlines():
        if line.startswith('"'):
            running_names.add(line.split('"')[1])
    vms = []
    for line in result.stdout.splitlines():
        if line.startswith('"'):
            name = line.split('"')[1]
            vms.append({"name": name, "running": name in running_names})
    return {"vms": vms}


@app.post("/tools/get_virtualbox_vm_status", operation_id="get_virtualbox_vm_status")
def get_virtualbox_vm_status(request: VirtualBoxVmRequest) -> dict[str, Any]:
    return get_linux_vm_status_payload(request.vm_name)


@app.post("/tools/ensure_virtualbox_nat_ssh_forward", operation_id="ensure_virtualbox_nat_ssh_forward")
def ensure_virtualbox_nat_ssh_forward(request: VirtualBoxVmRequest) -> dict[str, Any]:
    payload = ensure_virtualbox_nat_ssh_forward_impl(request.vm_name)
    host = str(LINUX_VM_CONFIG.get("ssh_host", "127.0.0.1"))
    port = int(LINUX_VM_CONFIG.get("ssh_port", 2222))
    payload["tcp_reachable"] = test_tcp_connect(host, port)
    return payload


@app.post("/tools/test_linux_vm_ssh", operation_id="test_linux_vm_ssh")
def test_linux_vm_ssh(request: VirtualBoxVmRequest) -> dict[str, Any]:
    if request.vm_name:
        get_linux_vm_status_payload(request.vm_name)
    payload = ensure_virtualbox_nat_ssh_forward_impl(request.vm_name)
    host = str(LINUX_VM_CONFIG.get("ssh_host", "127.0.0.1"))
    port = int(LINUX_VM_CONFIG.get("ssh_port", 2222))
    tcp_ok = test_tcp_connect(host, port)
    auth_ok = False
    auth_error = None
    if tcp_ok:
        try:
            client = connect_linux_vm()
            client.close()
            auth_ok = True
        except HTTPException as exc:
            auth_error = exc.detail
    return {
        **payload,
        "ssh_host": host,
        "ssh_port": port,
        "tcp_reachable": tcp_ok,
        "auth_ok": auth_ok,
        "auth_error": auth_error,
        "configured_user": LINUX_VM_CONFIG.get("ssh_user"),
        "detected_user": LINUX_VM_CONFIG.get("detected_user"),
    }


@app.post("/tools/linux_execute_shell", operation_id="linux_execute_shell")
def linux_execute_shell(request: LinuxVmShellRequest) -> dict[str, Any]:
    client = connect_linux_vm()
    try:
        command = request.command if not request.cwd else f"cd {request.cwd!r} && {request.command}"
        stdin, stdout, stderr = client.exec_command(command, timeout=request.timeout_sec)
        exit_code = stdout.channel.recv_exit_status()
        return {
            "exit_code": exit_code,
            "stdout": stdout.read().decode("utf-8", errors="replace"),
            "stderr": stderr.read().decode("utf-8", errors="replace"),
        }
    finally:
        client.close()


@app.post("/tools/linux_read_file", operation_id="linux_read_file")
def linux_read_file(request: LinuxVmPathRequest) -> dict[str, Any]:
    client = connect_linux_vm()
    try:
        sftp = client.open_sftp()
        with sftp.open(request.path, "r") as handle:
            content = handle.read().decode("utf-8", errors="replace")
        attrs = sftp.stat(request.path)
        if len(content) > request.max_chars:
            content = content[: request.max_chars] + "\n...<truncated>"
        return {"path": request.path, "size_bytes": attrs.st_size, "content": content}
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    finally:
        client.close()


@app.post("/tools/linux_write_file", operation_id="linux_write_file")
def linux_write_file(request: LinuxVmWriteFileRequest) -> dict[str, Any]:
    client = connect_linux_vm()
    try:
        sftp = client.open_sftp()
        mode = "a" if request.append else "w"
        with sftp.open(request.path, mode) as handle:
            handle.write(request.content)
        attrs = sftp.stat(request.path)
        return {"path": request.path, "size_bytes": attrs.st_size, "append": request.append}
    finally:
        client.close()


@app.post("/tools/linux_list_directory", operation_id="linux_list_directory")
def linux_list_directory(request: LinuxVmListDirectoryRequest) -> dict[str, Any]:
    client = connect_linux_vm()
    try:
        sftp = client.open_sftp()
        entries = []
        for item in sftp.listdir_attr(request.path)[: request.max_entries]:
            entries.append(
                {
                    "name": item.filename,
                    "path": f"{request.path.rstrip('/')}/{item.filename}",
                    "size_bytes": item.st_size,
                    "mode": item.st_mode,
                    "modified_at_epoch": item.st_mtime,
                }
            )
        return {"path": request.path, "entries": entries, "truncated": len(entries) >= request.max_entries}
    finally:
        client.close()


@app.post("/tools/linux_list_processes", operation_id="linux_list_processes")
def linux_list_processes(request: LinuxVmListProcessesRequest) -> dict[str, Any]:
    client = connect_linux_vm()
    try:
        filter_expr = request.name_filter or ""
        cmd = "ps -eo pid=,comm=,args= --no-headers"
        stdin, stdout, stderr = client.exec_command(cmd, timeout=60)
        exit_code = stdout.channel.recv_exit_status()
        if exit_code != 0:
            raise HTTPException(status_code=500, detail=stderr.read().decode("utf-8", errors="replace"))
        rows = []
        for line in stdout.read().decode("utf-8", errors="replace").splitlines():
            parts = line.strip().split(None, 2)
            if len(parts) < 2:
                continue
            pid, name = parts[0], parts[1]
            args = parts[2] if len(parts) > 2 else ""
            if filter_expr and filter_expr.lower() not in name.lower() and filter_expr.lower() not in args.lower():
                continue
            rows.append({"pid": int(pid), "name": name, "command_line": args})
            if len(rows) >= request.limit:
                break
        return {"processes": rows, "truncated": len(rows) >= request.limit}
    finally:
        client.close()


@app.post("/tools/kali_run_whois", operation_id="kali_run_whois")
def kali_run_whois(request: KaliWhoisRequest) -> dict[str, Any]:
    tool = get_effective_linux_tool_command("whois")
    query = ensure_safe_target_value(request.query, "query")
    return run_linux_command([tool, query], timeout_sec=request.timeout_sec, require_zero_exit=True)


@app.post("/tools/kali_run_dig", operation_id="kali_run_dig")
def kali_run_dig(request: KaliDigRequest) -> dict[str, Any]:
    tool = get_effective_linux_tool_command("dig")
    name = ensure_safe_target_value(request.name, "name")
    record_type = ensure_safe_target_value(request.record_type.upper(), "record_type")
    argv = [tool]
    if request.short:
        argv.append("+short")
    if request.dns_server:
        argv.append(f"@{ensure_safe_target_value(request.dns_server, 'dns_server')}")
    argv.extend([name, record_type])
    return run_linux_command(argv, timeout_sec=request.timeout_sec, require_zero_exit=True)


@app.post("/tools/kali_run_host", operation_id="kali_run_host")
def kali_run_host(request: KaliHostRequest) -> dict[str, Any]:
    tool = get_effective_linux_tool_command("host")
    name = ensure_safe_target_value(request.name, "name")
    record_type = ensure_safe_target_value(request.record_type.upper(), "record_type")
    argv = [tool, "-t", record_type, name]
    if request.dns_server:
        argv.append(ensure_safe_target_value(request.dns_server, "dns_server"))
    return run_linux_command(argv, timeout_sec=request.timeout_sec, require_zero_exit=True)


@app.post("/tools/kali_run_nslookup", operation_id="kali_run_nslookup")
def kali_run_nslookup(request: KaliNslookupRequest) -> dict[str, Any]:
    tool = get_effective_linux_tool_command("nslookup")
    name = ensure_safe_target_value(request.name, "name")
    query_type = ensure_safe_target_value(request.query_type.upper(), "query_type")
    argv = [tool, "-type=" + query_type, name]
    if request.dns_server:
        argv.append(ensure_safe_target_value(request.dns_server, "dns_server"))
    return run_linux_command(argv, timeout_sec=request.timeout_sec, require_zero_exit=True)


@app.post("/tools/kali_run_curl", operation_id="kali_run_curl")
def kali_run_curl(request: KaliCurlRequest) -> dict[str, Any]:
    tool = get_effective_linux_tool_command("curl")
    url = ensure_safe_target_value(request.url, "url")
    argv = [tool, "--silent", "--show-error", "--max-time", str(request.timeout_sec)]
    if request.include_headers:
        argv.append("--include")
    if request.follow_redirects:
        argv.append("--location")
    if not request.verify_tls:
        argv.append("--insecure")
    if request.method == "HEAD":
        argv.append("--head")
    argv.append(url)
    return run_linux_command(argv, timeout_sec=request.timeout_sec + 10, require_zero_exit=True)


@app.post("/tools/kali_run_wget", operation_id="kali_run_wget")
def kali_run_wget(request: KaliWgetRequest) -> dict[str, Any]:
    tool = get_effective_linux_tool_command("wget")
    url = ensure_safe_target_value(request.url, "url")
    argv = [tool, "--timeout", str(request.timeout_sec), "-O", "-"]
    if request.spider:
        argv.extend(["--spider", "-S"])
    elif request.server_response:
        argv.append("--server-response")
    if not request.follow_redirects:
        argv.append("--max-redirect=0")
    if not request.verify_tls:
        argv.append("--no-check-certificate")
    argv.append(url)
    return run_linux_command(argv, timeout_sec=request.timeout_sec + 10, require_zero_exit=True)


@app.post("/tools/kali_run_whatweb", operation_id="kali_run_whatweb")
def kali_run_whatweb(request: KaliWhatwebRequest) -> dict[str, Any]:
    tool = get_effective_linux_tool_command("whatweb")
    url = ensure_safe_target_value(request.url, "url")
    return run_linux_command([tool, f"--aggression={request.aggression}", url], timeout_sec=request.timeout_sec, require_zero_exit=True)


@app.post("/tools/kali_run_wafw00f", operation_id="kali_run_wafw00f")
def kali_run_wafw00f(request: KaliWafw00fRequest) -> dict[str, Any]:
    tool = get_effective_linux_tool_command("wafw00f")
    url = ensure_safe_target_value(request.url, "url")
    argv = [tool, url, "--no-colors", "-T", str(request.timeout_sec)]
    if request.find_all:
        argv.append("-a")
    if request.no_redirect:
        argv.append("-r")
    return run_linux_command(argv, timeout_sec=request.timeout_sec + 10, require_zero_exit=True)


@app.post("/tools/kali_run_nikto", operation_id="kali_run_nikto")
def kali_run_nikto(request: KaliNiktoRequest) -> dict[str, Any]:
    tool = get_effective_linux_tool_command("nikto")
    target_url = ensure_safe_target_value(request.target_url, "target_url")
    return run_linux_command([tool, "-h", target_url, "-ask", "no"], timeout_sec=request.timeout_sec, require_zero_exit=True)


@app.post("/tools/kali_run_wapiti", operation_id="kali_run_wapiti")
def kali_run_wapiti(request: KaliWapitiRequest) -> dict[str, Any]:
    tool = get_effective_linux_tool_command("wapiti")
    target_url = ensure_safe_target_value(request.target_url, "target_url")
    modules = ensure_safe_target_value(request.modules, "modules")
    return run_linux_command(
        [tool, "-u", target_url, "--scope", request.scope, "-m", modules, "--format", "txt", "--flush-session"],
        timeout_sec=request.timeout_sec,
        require_zero_exit=True,
    )


@app.post("/tools/kali_run_traceroute", operation_id="kali_run_traceroute")
def kali_run_traceroute(request: KaliTracerouteRequest) -> dict[str, Any]:
    tool = get_effective_linux_tool_command("traceroute")
    host = ensure_safe_target_value(request.host, "host")
    argv = [tool, "-m", str(request.max_hops), "-q", str(request.queries)]
    if request.numeric:
        argv.append("-n")
    if request.method == "tcp":
        argv.append("-T")
    elif request.method == "icmp":
        argv.append("-I")
    else:
        argv.append("-U")
    if request.port:
        argv.extend(["-p", str(request.port)])
    argv.append(host)
    return run_linux_command(argv, timeout_sec=request.timeout_sec, require_zero_exit=True)


@app.post("/tools/kali_run_fping", operation_id="kali_run_fping")
def kali_run_fping(request: KaliFpingRequest) -> dict[str, Any]:
    tool = get_effective_linux_tool_command("fping")
    if not request.targets:
        raise HTTPException(status_code=400, detail="targets must contain at least one host.")
    targets = [ensure_safe_target_value(target, "targets item") for target in request.targets]
    argv = [tool, "-c", str(request.count), "-t", str(request.timeout_ms)]
    if request.show_alive:
        argv.append("-a")
    argv.extend(targets)
    return run_linux_command(argv, timeout_sec=request.timeout_sec, require_zero_exit=True)


@app.post("/tools/kali_run_arp_scan", operation_id="kali_run_arp_scan")
def kali_run_arp_scan(request: KaliArpScanRequest) -> dict[str, Any]:
    tool = get_effective_linux_tool_command("arp-scan")
    argv = [tool]
    if request.interface:
        argv.extend(["--interface", ensure_safe_target_value(request.interface, "interface")])
    if request.plain:
        argv.append("--plain")
    if request.localnet:
        argv.append("--localnet")
    else:
        if not request.targets:
            raise HTTPException(status_code=400, detail="targets must contain at least one host when localnet is false.")
        argv.extend([ensure_safe_target_value(target, "targets item") for target in request.targets])
    return run_linux_command(argv, timeout_sec=request.timeout_sec, require_zero_exit=True)


@app.post("/tools/kali_run_netcat_probe", operation_id="kali_run_netcat_probe")
def kali_run_netcat_probe(request: KaliNetcatProbeRequest) -> dict[str, Any]:
    tool = get_effective_linux_tool_command("nc")
    host = ensure_safe_target_value(request.host, "host")
    argv = [tool, "-z", "-w", str(request.timeout_sec)]
    if request.verbose:
        argv.append("-v")
    if request.udp:
        argv.append("-u")
    argv.extend([host, str(request.port)])
    return run_linux_command(argv, timeout_sec=request.timeout_sec + 10, require_zero_exit=True)


@app.post("/tools/kali_run_tcpdump_capture", operation_id="kali_run_tcpdump_capture")
def kali_run_tcpdump_capture(request: KaliTcpdumpCaptureRequest) -> dict[str, Any]:
    tool = get_effective_linux_tool_command("tcpdump")
    interface = ensure_safe_target_value(request.interface, "interface")
    output_path = ensure_safe_target_value(request.output_path, "output_path") if request.output_path else build_linux_artifact_path("tcpdump-capture", ".pcap")
    ensure_linux_directory(posixpath.dirname(output_path) or "/tmp", "output_parent")

    argv: list[str] = [tool, "-i", interface, "-n", "-U", "-w", output_path, "-s", str(request.snapshot_length)]
    if request.no_promiscuous:
        argv.append("-p")
    if request.packet_count:
        argv.extend(["-c", str(request.packet_count)])
    if request.capture_filter:
        argv.append(ensure_safe_target_value(request.capture_filter, "capture_filter"))

    timeout_budget = request.timeout_sec
    if request.duration_sec:
        argv = ["timeout", str(request.duration_sec)] + argv
        timeout_budget = max(timeout_budget, request.duration_sec + 10)

    result = run_linux_command(argv, timeout_sec=timeout_budget, require_zero_exit=False)
    if result["exit_code"] not in (0, 124):
        raise HTTPException(status_code=500, detail=result)

    stat_result = run_linux_command(["stat", "-c", "%s", output_path], timeout_sec=15, require_zero_exit=True)
    size_bytes = int((stat_result["stdout"] or "0").strip() or "0")
    if size_bytes <= 0:
        raise HTTPException(status_code=500, detail=f"tcpdump capture file '{output_path}' was created but is empty.")

    return {
        **result,
        "capture_path": output_path,
        "size_bytes": size_bytes,
    }


@app.post("/tools/kali_run_tshark_summary", operation_id="kali_run_tshark_summary")
def kali_run_tshark_summary(request: KaliTsharkSummaryRequest) -> dict[str, Any]:
    tool = get_effective_linux_tool_command("tshark")
    pcap_path = ensure_linux_file_exists(request.pcap_path, "pcap_path")
    argv = [tool, "-r", pcap_path, "-n", "-c", str(request.max_packets)]
    if request.display_filter:
        argv.extend(["-Y", ensure_safe_target_value(request.display_filter, "display_filter")])
    return run_linux_command(argv, timeout_sec=request.timeout_sec, require_zero_exit=True)


@app.post("/tools/kali_run_tshark_protocol_hierarchy", operation_id="kali_run_tshark_protocol_hierarchy")
def kali_run_tshark_protocol_hierarchy(request: KaliTsharkProtocolHierarchyRequest) -> dict[str, Any]:
    tool = get_effective_linux_tool_command("tshark")
    pcap_path = ensure_linux_file_exists(request.pcap_path, "pcap_path")
    argv = [tool, "-r", pcap_path, "-q", "-z", "io,phs"]
    if request.display_filter:
        argv.extend(["-Y", ensure_safe_target_value(request.display_filter, "display_filter")])
    return run_linux_command(argv, timeout_sec=request.timeout_sec, require_zero_exit=True)


@app.post("/tools/kali_run_tshark_conversations", operation_id="kali_run_tshark_conversations")
def kali_run_tshark_conversations(request: KaliTsharkConversationsRequest) -> dict[str, Any]:
    tool = get_effective_linux_tool_command("tshark")
    pcap_path = ensure_linux_file_exists(request.pcap_path, "pcap_path")
    argv = [tool, "-r", pcap_path, "-q", "-z", f"conv,{request.conversation_type}"]
    if request.display_filter:
        argv.extend(["-Y", ensure_safe_target_value(request.display_filter, "display_filter")])
    return run_linux_command(argv, timeout_sec=request.timeout_sec, require_zero_exit=True)


@app.post("/tools/kali_run_tshark_fields", operation_id="kali_run_tshark_fields")
def kali_run_tshark_fields(request: KaliTsharkFieldsRequest) -> dict[str, Any]:
    tool = get_effective_linux_tool_command("tshark")
    pcap_path = ensure_linux_file_exists(request.pcap_path, "pcap_path")
    if not request.fields:
        raise HTTPException(status_code=400, detail="fields must contain at least one tshark field.")
    separator_value = {"tab": "/t", "comma": ",", "space": "/s"}[request.separator]
    argv = [tool, "-r", pcap_path, "-n", "-T", "fields", "-c", str(request.max_packets), f"-Eheader={'y' if request.include_header else 'n'}", f"-Eseparator={separator_value}"]
    if request.display_filter:
        argv.extend(["-Y", ensure_safe_target_value(request.display_filter, "display_filter")])
    for field in request.fields:
        argv.extend(["-e", ensure_safe_target_value(field, "fields item")])
    return run_linux_command(argv, timeout_sec=request.timeout_sec, require_zero_exit=True)


@app.post("/tools/kali_run_nmap", operation_id="kali_run_nmap")
def kali_run_nmap(request: KaliNmapRequest) -> dict[str, Any]:
    tool = get_effective_linux_tool_command("nmap")
    target = ensure_safe_target_value(request.target, "target")
    argv = [tool]
    if request.ports:
        argv.extend(["-p", ensure_safe_target_value(request.ports, "ports")])
    elif request.top_ports:
        argv.extend(["--top-ports", str(request.top_ports)])
    if request.service_version:
        argv.append("-sV")
    if request.default_scripts:
        argv.append("-sC")
    argv.append(target)
    return run_linux_command(argv, timeout_sec=request.timeout_sec, require_zero_exit=True)


@app.post("/tools/kali_run_sslscan", operation_id="kali_run_sslscan")
def kali_run_sslscan(request: KaliSslscanRequest) -> dict[str, Any]:
    tool = get_effective_linux_tool_command("sslscan")
    host = ensure_safe_target_value(request.host, "host")
    return run_linux_command([tool, f"{host}:{request.port}"], timeout_sec=request.timeout_sec, require_zero_exit=True)


@app.post("/tools/kali_run_sslyze", operation_id="kali_run_sslyze")
def kali_run_sslyze(request: KaliSslyzeRequest) -> dict[str, Any]:
    tool = get_effective_linux_tool_command("sslyze")
    target = ensure_safe_target_value(request.target, "target")
    argv = [tool]
    if request.sni:
        argv.extend(["--sni", ensure_safe_target_value(request.sni, "sni")])
    if request.mozilla_config != "disable":
        argv.extend(["--mozilla_config", request.mozilla_config])
    else:
        argv.extend(["--mozilla_config", "disable"])
    if request.certinfo:
        argv.append("--certinfo")
    if request.http_headers:
        argv.append("--http_headers")
    if request.tlsv1_2:
        argv.append("--tlsv1_2")
    if request.tlsv1_3:
        argv.append("--tlsv1_3")
    argv.append(target)
    return run_linux_command(argv, timeout_sec=request.timeout_sec, require_zero_exit=True)


@app.post("/tools/kali_run_openssl_s_client", operation_id="kali_run_openssl_s_client")
def kali_run_openssl_s_client(request: KaliOpenSslSClientRequest) -> dict[str, Any]:
    tool = get_effective_linux_tool_command("openssl")
    host = ensure_safe_target_value(request.host, "host")
    argv = [tool, "s_client", "-connect", f"{host}:{request.port}"]
    servername = request.servername or host
    argv.extend(["-servername", ensure_safe_target_value(servername, "servername")])
    if request.tls_version != "auto":
        argv.append("-" + request.tls_version)
    if request.show_certs:
        argv.append("-showcerts")
    if request.brief:
        argv.append("-brief")
    argv.extend(["-ign_eof", "-no_ign_eof"])
    return run_linux_command(argv, timeout_sec=request.timeout_sec, require_zero_exit=True)


@app.post("/tools/kali_run_httpx", operation_id="kali_run_httpx")
def kali_run_httpx(request: KaliHttpxRequest) -> dict[str, Any]:
    tool = get_effective_linux_tool_command("httpx")
    url = ensure_safe_target_value(request.url, "url")
    argv = [tool, url, "--method", request.method, "--timeout", str(request.timeout_sec)]
    if request.follow_redirects:
        argv.append("--follow-redirects")
    if not request.verify_tls:
        argv.append("--no-verify")
    if request.verbose:
        argv.append("--verbose")
    return run_linux_command(argv, timeout_sec=request.timeout_sec + 10, require_zero_exit=True)


@app.post("/tools/kali_run_dnsenum", operation_id="kali_run_dnsenum")
def kali_run_dnsenum(request: KaliDomainRequest) -> dict[str, Any]:
    tool = get_effective_linux_tool_command("dnsenum")
    domain = ensure_safe_target_value(request.domain, "domain")
    return run_linux_command([tool, "--noreverse", domain], timeout_sec=request.timeout_sec, require_zero_exit=True)


@app.post("/tools/kali_run_dnsrecon", operation_id="kali_run_dnsrecon")
def kali_run_dnsrecon(request: KaliDomainRequest) -> dict[str, Any]:
    tool = get_effective_linux_tool_command("dnsrecon")
    domain = ensure_safe_target_value(request.domain, "domain")
    return run_linux_command([tool, "-d", domain], timeout_sec=request.timeout_sec, require_zero_exit=True)


@app.post("/tools/kali_run_smbclient_list_shares", operation_id="kali_run_smbclient_list_shares")
def kali_run_smbclient_list_shares(request: KaliSmbclientAuthRequest) -> dict[str, Any]:
    tool = get_effective_linux_tool_command("smbclient")
    host = ensure_safe_target_value(request.host, "host")
    argv = [tool, "-L", host, "-p", str(request.port), "-g", "-t", str(request.timeout_sec)]
    argv.extend(build_smbclient_auth_args(request.username, request.password, request.workgroup))
    return run_linux_command(argv, timeout_sec=request.timeout_sec + 10, require_zero_exit=True)


@app.post("/tools/kali_run_smbclient_list_path", operation_id="kali_run_smbclient_list_path")
def kali_run_smbclient_list_path(request: KaliSmbclientListPathRequest) -> dict[str, Any]:
    tool = get_effective_linux_tool_command("smbclient")
    host = ensure_safe_target_value(request.host, "host")
    share = ensure_safe_target_value(request.share, "share")
    remote_path = ensure_safe_target_value(request.remote_path, "remote_path")
    argv = [tool, f"//{host}/{share}", "-p", str(request.port), "-g", "-t", str(request.timeout_sec), "-c", f'ls "{remote_path}"']
    argv.extend(build_smbclient_auth_args(request.username, request.password, request.workgroup))
    return run_linux_command(argv, timeout_sec=request.timeout_sec + 10, require_zero_exit=True)


@app.post("/tools/kali_run_smbclient_get_file", operation_id="kali_run_smbclient_get_file")
def kali_run_smbclient_get_file(request: KaliSmbclientGetFileRequest) -> dict[str, Any]:
    tool = get_effective_linux_tool_command("smbclient")
    host = ensure_safe_target_value(request.host, "host")
    share = ensure_safe_target_value(request.share, "share")
    remote_path = ensure_safe_target_value(request.remote_path, "remote_path")
    if request.local_output_path:
        local_output_path = ensure_safe_target_value(request.local_output_path, "local_output_path")
        ensure_linux_directory(posixpath.dirname(local_output_path) or "/tmp", "local_output_parent")
    else:
        remote_name = posixpath.basename(remote_path) or "smb-file.bin"
        suffix = posixpath.splitext(remote_name)[1] or ".bin"
        local_output_path = build_linux_artifact_path("smbclient-get", suffix)
    argv = [tool, f"//{host}/{share}", "-p", str(request.port), "-g", "-t", str(request.timeout_sec), "-c", f'get "{remote_path}" "{local_output_path}"']
    argv.extend(build_smbclient_auth_args(request.username, request.password, request.workgroup))
    result = run_linux_command(argv, timeout_sec=request.timeout_sec + 10, require_zero_exit=True)
    stat_result = run_linux_command(["stat", "-c", "%s", local_output_path], timeout_sec=15, require_zero_exit=True)
    return {
        **result,
        "local_output_path": local_output_path,
        "size_bytes": int((stat_result["stdout"] or "0").strip() or "0"),
    }


@app.post("/tools/kali_run_enum4linux_basic", operation_id="kali_run_enum4linux_basic")
def kali_run_enum4linux_basic(request: KaliEnum4linuxBasicRequest) -> dict[str, Any]:
    tool = get_effective_linux_tool_command("enum4linux")
    host = ensure_safe_target_value(request.host, "host")
    argv = [tool]
    if request.users:
        argv.append("-U")
    if request.shares:
        argv.append("-S")
    if request.groups:
        argv.append("-G")
    if request.password_policy:
        argv.append("-P")
    if request.os_info:
        argv.append("-o")
    if request.rid_cycle:
        argv.append("-r")
    if not any([request.users, request.shares, request.groups, request.password_policy, request.os_info, request.rid_cycle]):
        argv.append("-a")
    if request.username:
        argv.extend(["-u", ensure_safe_target_value(request.username, "username")])
    if request.password is not None:
        argv.extend(["-p", request.password])
    argv.append(host)
    result = run_linux_command(argv, timeout_sec=request.timeout_sec + 10, require_zero_exit=False)
    if result["exit_code"] not in (0, 1):
        raise HTTPException(status_code=500, detail=result)
    return result


@app.post("/tools/kali_run_gobuster_dir", operation_id="kali_run_gobuster_dir")
def kali_run_gobuster_dir(request: KaliGobusterDirRequest) -> dict[str, Any]:
    tool = get_effective_linux_tool_command("gobuster")
    base_url = ensure_safe_target_value(request.base_url, "base_url")
    wordlist_path = ensure_linux_file_exists(request.wordlist_path, "wordlist_path")
    argv = [tool, "dir", "-u", base_url, "-w", wordlist_path, "-t", str(request.threads), "--no-error"]
    if request.extensions:
        sanitized = [ensure_safe_target_value(ext, "extensions item").lstrip(".") for ext in request.extensions]
        argv.extend(["-x", ",".join(sanitized)])
    return run_linux_command(argv, timeout_sec=request.timeout_sec, require_zero_exit=True)


@app.post("/tools/kali_run_amass_passive", operation_id="kali_run_amass_passive")
def kali_run_amass_passive(request: KaliDomainRequest) -> dict[str, Any]:
    tool = get_effective_linux_tool_command("amass")
    domain = ensure_safe_target_value(request.domain, "domain")
    timeout_minutes = max(1, min(60, (request.timeout_sec + 59) // 60))
    return run_linux_command(
        [tool, "enum", "-passive", "-nocolor", "-silent", "-timeout", str(timeout_minutes), "-d", domain],
        timeout_sec=request.timeout_sec + 15,
        require_zero_exit=True,
    )
