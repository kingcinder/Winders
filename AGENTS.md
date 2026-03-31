# AGENTS.md

## Project mission

This repo exists to produce a one-shot, rerunnable, repairable Windows local-LLM stack for:

- AMD RX 5700 XT
- Ryzen 7 3700X
- 32GB RAM
- Windows x64
- Vulkan backend
- NO ROCm
- llama.cpp backend
- Open WebUI frontend
- local-only operation

The intended install root is `C:\LocalLLM`.

The expected user experience is:

1. Run one PowerShell bootstrap script
2. Wait for install/verification
3. Browser opens to local UI
4. Stack is usable
5. Reruns repair or verify instead of breaking working state

## Engineering rules

### 1) Reliability beats elegance
Prefer the implementation most likely to work on the first run and on reruns.

Do not optimize for minimal code size if it reduces survivability.

### 2) Treat the machine as hostile
Assume the following are common and must be handled:

- partial previous installs
- stale processes
- broken configs
- bad PATH state
- Docker installed but daemon not running
- ports 3000/8080 already in use
- GitHub download failures
- archive naming/layout drift
- antivirus/firewall friction
- missing or invalid model files
- ambiguous Vulkan device selection
- backend process that starts but never becomes healthy
- UI container that runs but cannot reach backend

### 3) Idempotence is mandatory
All setup and repair flows must be safe to rerun.

If state exists:
- verify it
- reuse it if healthy
- repair in place if unhealthy
- replace only when necessary

### 4) Centralize configuration
Use one config location for:
- install root
- ports
- context length
- default model path
- smoke-test model repo
- GPU index override
- auth toggle
- browser auto-open behavior
- log paths

Launchers and repair scripts must read from the same config source.

### 5) Every important action needs verification
After installation or repair, verify:
- backend binary exists
- backend starts
- `/health` answers
- `/v1/models` answers
- UI is reachable
- Docker container is healthy enough to serve requests
- chosen GPU index is persisted
- model file path exists when using local model mode

### 6) Log everything important
