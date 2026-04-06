# Winders

Winders builds a rerunnable Windows local-LLM stack under `C:\LocalLLM` for:

- `llama.cpp` backend
- Vulkan on Windows x64
- Open WebUI frontend
- local OpenAPI tool server for host control
- local-only operation

## Primary bootstrap

Run the full bootstrap:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup-local-llm-stack.ps1
```

The bootstrap still requires an elevated Windows shell because the actual stack installs under `C:\LocalLLM`.

Compatibility entrypoints remain available:

- `setup-local-llm.ps1`: install or update the backend runtime and launchers
- `setup-openwebui-for-local-llm.ps1`: verify or repair only the Open WebUI side

## Operator commands

After install, the working scripts live under `C:\LocalLLM\scripts`:

- `START-STACK.cmd`
- `REPAIR-STACK.ps1`
- `status-stack.ps1`
- `SELF-TEST-STACK.ps1`
- `START-TOOLSERVER.cmd`
- `STOP-TOOLSERVER.cmd`
- `status-toolserver.ps1`

Self-test:

```powershell
powershell -ExecutionPolicy Bypass -File C:\LocalLLM\scripts\SELF-TEST-STACK.ps1
```

Local model selection:

- `INITIALIZE-MODEL-SELECTION.cmd` is the obvious first step for local GGUF use. It creates/opens `C:\LocalLLM\models`, waits for at least one `.gguf`, and then launches the selector.
- `START-LOCAL-MODEL.cmd` prompts for a local GGUF and now enumerates `C:\LocalLLM\models` first.
- `START-MODELS-DIR.cmd` uses that same selector, so the canonical local model folder is `C:\LocalLLM\models`.

Streaming voice:

- Open WebUI can use a local Kokoro CPU TTS sidecar and a Chromium extension from `C:\LocalLLM\browser-tts-extension` for sentence-by-sentence autoplay voice.
- On this target hardware the streaming browser TTS path is disabled by default in favor of system stability.
- If you explicitly re-enable `TtsEnabled` and `StreamingTtsAutoplayEnabled`, `start-openwebui.ps1` will load the extension through Edge/Chrome. If Chromium is unavailable, the stack falls back to a normal browser open without autoplay voice.

## Behavior guarantees

- Backend success requires both `/health` and `/v1/models`.
- Open WebUI reuses a healthy matching container and only recreates on missing container, drift, unhealthy state, or failed recovery.
- Open WebUI tool access is provided by a locally hosted OpenAPI server on this machine. No paid API or external runtime service is required.
- The local tool server defaults to `standard` sandbox mode and supports explicit `override` mode for broader host mutation.
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
