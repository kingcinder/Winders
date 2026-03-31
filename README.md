# Local Windows LLM Stack Bootstrap (AMD RX 5700 XT, Vulkan, **NO ROCm**)

This repo provides a **single-entry, rerunnable, repair-oriented** Windows bootstrap for a local LLM stack:

- Backend: `llama.cpp` server (Windows x64 Vulkan build)
- Frontend: Open WebUI in Docker Desktop
- API: `http://127.0.0.1:8080/v1`
- UI: `http://127.0.0.1:3000`
- Install root: `C:\LocalLLM`

## Hardware target

- AMD RX 5700 XT
- Ryzen 7 3700X
- 32GB RAM
- Windows x64
- Vulkan backend only
- **NO ROCm**

## Prerequisites

1. Windows 10/11 x64
2. PowerShell 5.1+
3. Docker Desktop installed (for Open WebUI)
4. Internet access during bootstrap (GitHub + container image + optional Hugging Face smoke model pull)

## One-line install/run

Open **elevated** PowerShell in this repo and run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\setup-local-llm-stack.ps1
```

The bootstrap will:

1. Create/verify `C:\LocalLLM` layout
2. Persist central config to `C:\LocalLLM\config\stack.json`
3. Install latest official llama.cpp Windows Vulkan release
4. Detect/select Vulkan GPU index and persist it
5. Write command launchers and helper scripts under `C:\LocalLLM\scripts`
6. Repair/start backend + Open WebUI
7. Validate `/health`, `/v1/models`, and UI reachability

## Daily operations

```cmd
C:\LocalLLM\scripts\START-STACK.cmd
C:\LocalLLM\scripts\STOP-STACK.cmd
C:\LocalLLM\scripts\STATUS-STACK.cmd
C:\LocalLLM\scripts\TEST-API.cmd
C:\LocalLLM\scripts\START-BACKEND.cmd
C:\LocalLLM\scripts\START-OPENWEBUI.cmd
```

## Folder layout

```text
C:\LocalLLM
├─ bin\                      # llama.cpp binaries including llama-server.exe
├─ config\
│  └─ stack.json              # central stack config (single source of truth)
├─ logs\
│  ├─ bootstrap.log
│  ├─ backend.log
│  └─ openwebui.log
├─ models\
│  └─ model.gguf              # local model default path
├─ openwebui\
│  ├─ compose.yaml
│  └─ data\                  # persistent Open WebUI data
├─ scripts\                  # launchers + repair + status + test
└─ state\
   ├─ gpu-index.txt
   ├─ llama_devices_raw.txt
   └─ install-state.json
```

## Config (single source of truth)

Main config file: `C:\LocalLLM\config\stack.json`

Key settings:

- `InstallRoot`
- `BackendHost`, `BackendPort`
- `FrontendHost`, `FrontendPort`
- `LocalModelPath`
- `ContextLength`
- `GPUIndexOverride`
- `SmokeTestRepo`, `SmokeTestFile`
- `DisableWebUIAuth`
- `AutoOpenBrowser`
- `BackendPidFileName`, `BackendStdOutLogName`, `BackendStdErrLogName`
- `LlamaReleaseApi` (override only if upstream API endpoint changes)

### Swap models

- Put local GGUF at `C:\LocalLLM\models\model.gguf`, or
- Update `LocalModelPath` in `stack.json` and run:

```cmd
C:\LocalLLM\scripts\REPAIR-STACK.ps1
```

### Override GPU index

Set `GPUIndexOverride` to a numeric index in `stack.json`, then run repair:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\LocalLLM\scripts\REPAIR-STACK.ps1
```

## Repair and uninstall

Repair deterministic flow:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\LocalLLM\scripts\REPAIR-STACK.ps1
```

Optional removal:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\LocalLLM\scripts\REMOVE-STACK.ps1
```

## Common failure cases and exact fixes

1. **Docker CLI missing from PATH**
   - Symptom: `Docker CLI not found in PATH`
   - Fix: Install Docker Desktop, restart shell, rerun bootstrap.

2. **Docker daemon not running**
   - Symptom: `docker version` retry failure
   - Fix: Launch Docker Desktop and wait for engine running, then rerun repair.

3. **Port 8080/3000 already in use**
   - Symptom: setup/repair reports owning PID/name
   - Fix: stop owning process or change ports in `stack.json`, rerun repair.

4. **GitHub asset naming drift**
   - Symptom: no Vulkan Windows x64 zip selected
   - Fix: inspect `logs\bootstrap.log`, confirm latest release assets, rerun after adjusting selector logic if upstream changed naming.

5. **Extraction succeeded but `llama-server.exe` missing**
   - Symptom: explicit post-extraction binary not found error
   - Fix: likely upstream archive layout change or blocked extraction; inspect antivirus + log, rerun repair.

6. **`--list-devices` parse ambiguity**
   - Symptom: warning in bootstrap log; deterministic first best candidate used
   - Fix: set `GPUIndexOverride` explicitly and rerun repair.

7. **Backend process alive but health endpoint fails**
   - Symptom: timeout waiting for `/health`
   - Fix: run `STATUS-STACK.cmd`, inspect `backend.log`, then run repair.

8. **Open WebUI running but cannot reach backend**
   - Symptom: UI comes up but no model connectivity
   - Fix: verify backend on `http://127.0.0.1:8080/v1/models`; then restart UI via `STOP-OPENWEBUI.cmd` and `START-OPENWEBUI.cmd`.

9. **Repair script fails from installed path due to config path mismatch**
   - Mechanism: scripts were executed from `C:\LocalLLM\scripts` while reading repo-relative config.
   - Current handling: scripts now resolve config from installed `C:\LocalLLM\config\stack.json` first, then fall back to repo config.

10. **Backend redirect failure due to stdout/stderr collision**
   - Mechanism: Windows `Start-Process` can fail if both redirections use the same file path.
   - Current handling: backend now writes to separate `backend-stdout.log` and `backend-stderr.log`, plus merged summary in `backend.log`.

## Legacy scripts

- `setup-local-llm.ps1` and `setup-openwebui-for-local-llm.ps1` are kept as **deprecated compatibility shims** that forward to the new flow.

## Stress-test coverage (scripted failure mechanisms)

The implementation includes explicit handling for:

- Missing/invalid config file path resolution when run from repo vs installed root.
- Missing `llama-server.exe` on rerun (auto-installs latest Vulkan release in repair flow).
- GitHub release API/query/download transient failures (retry with bounded attempts).
- Release-asset drift where no Windows Vulkan zip is discoverable (hard-fail with exact observed asset names).
- Port conflicts on 8080/3000 with owning PID/process surfaced.
- Existing backend process that is alive but unhealthy (fail with exact stop/start command path).
- Docker CLI missing vs daemon unavailable (separate diagnostics).
- Open WebUI container created but not actually running/reachable (inspect + logs + fail fast).

## Design notes

### Known

- Stack is Windows-only and x64-only.
- Backend uses llama.cpp Vulkan binary selection from official latest GitHub release.
- Frontend uses Dockerized Open WebUI with persistent data at `C:\LocalLLM\openwebui\data`.

### Assumed

- User can run elevated PowerShell for initial setup in `C:\`.
- Docker Desktop supports `host.docker.internal` and `host-gateway` mapping.
- Network path to GitHub/container registry/Hugging Face is available during setup.

### Inference-based parsing

- GitHub asset selection uses scoring heuristics across asset names (Vulkan + Windows + x64, with negative weighting for CUDA/ROCm/Metal/SYCL variants).
- `llama-server --list-devices` parsing uses multiple index patterns and score-based candidate ranking (favoring RX 5700 XT/NAVI10/AMD). If tied, first candidate is selected deterministically.

## Acceptance checklist

- [ ] Run one script: `setup-local-llm-stack.ps1`
- [ ] `llama-server.exe` exists under `C:\LocalLLM\bin`
- [ ] `http://127.0.0.1:8080/health` returns success
- [ ] `http://127.0.0.1:8080/v1/models` returns success
- [ ] `http://127.0.0.1:3000` reachable
- [ ] `STATUS-STACK.cmd` identifies current state and failure domain
- [ ] Re-running bootstrap does not damage healthy install
