# Winders

This repository builds and repairs a Windows local-LLM stack under `C:\LocalLLM`.

Runtime commands after setup:

- `C:\LocalLLM\scripts\start-backend.ps1`
- `C:\LocalLLM\scripts\start-openwebui.ps1`
- `C:\LocalLLM\scripts\start-stack.ps1`
- `C:\LocalLLM\scripts\REPAIR-STACK.ps1`
- `C:\LocalLLM\scripts\status-stack.ps1`
- `C:\LocalLLM\scripts\SELF-TEST-STACK.ps1`

State is persisted at `C:\LocalLLM\state\install-state.json`. Key fields:

- `BackendMode = local | smoke-test`
- `LastModelRequested`
- `LastModelActuallyUsed`
- `FallbackTriggered`
- `LastStartReason`
- `LastSuccessfulBackendReadyAt`

Operator notes:

- Backend readiness requires both `/health` and `/v1/models`.
- Status distinguishes `/health OK + /v1/models FAIL` as degraded or broken, not ready.
- If local-model startup fails, the stack can fall back to smoke-test mode and records that explicitly in state.

Self-test command:

```powershell
powershell -ExecutionPolicy Bypass -File C:\LocalLLM\scripts\SELF-TEST-STACK.ps1
```
