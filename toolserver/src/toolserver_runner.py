from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import uvicorn


def main() -> int:
    if len(sys.argv) < 2:
        raise SystemExit("Usage: toolserver_runner.py <config-path>")

    config_path = Path(sys.argv[1]).resolve()
    os.environ["TOOLSERVER_CONFIG_PATH"] = str(config_path)

    with config_path.open("r", encoding="utf-8-sig") as handle:
        config = json.load(handle)

    server = config["server"]
    uvicorn.run(
        "toolserver_app:app",
        host=server["bind_host"],
        port=int(server["port"]),
        app_dir=str(Path(__file__).resolve().parent),
        log_level="info",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
