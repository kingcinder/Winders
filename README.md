# Winders

Winders builds a rerunnable Windows local-LLM stack under `C:\LocalLLM` for:

- `llama.cpp` backend
- Vulkan on Windows x64
- Open WebUI frontend
- local-only operation

## Primary bootstrap

Run the full bootstrap:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup-local-llm-stack.ps1
```

Compatibility entrypoints remain available:

- `setup-local-llm.ps1`: install or update the backend runtime and launchers
- `setup-openwebui-for-local-llm.ps1`: verify or repair only the Open WebUI side

## Operator commands

After install, the working scripts live under `C:\LocalLLM\scripts`:

- `START-STACK.cmd`
- `REPAIR-STACK.ps1`
- `status-stack.ps1`
- `SELF-TEST-STACK.ps1`

Self-test:

```powershell
powershell -ExecutionPolicy Bypass -File C:\LocalLLM\scripts\SELF-TEST-STACK.ps1
```

## Behavior guarantees

- Backend success requires both `/health` and `/v1/models`.
- Open WebUI reuses a healthy matching container and only recreates on missing container, drift, unhealthy state, or failed recovery.
- Repair prefers verify, then reuse, then targeted repair of only the broken component.
- Backend ownership distinguishes this stack from unrelated `llama-server` processes before any stop or repair action.

## Persistent state

State is stored at `C:\LocalLLM\state\install-state.json` and includes:

- `BackendMode = local | smoke-test`
- `LastModelRequested`
- `LastModelActuallyUsed`
- `FallbackTriggered`
- `LastStartReason`
- `LastSuccessfulBackendReadyAt`
- `OpenWebUiConfigFingerprint`

If local model startup fails and smoke-test fallback is used, `status-stack.ps1` and `SELF-TEST-STACK.ps1` report that explicitly.
