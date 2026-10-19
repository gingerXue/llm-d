#!/usr/bin/env python3
"""Acquire a GPU lease for the MThreads DeepSeek 1P1D deployment.

The broker is accessed through its keyless MCP HTTP endpoint.  The process
keeps the lease alive while the Kubernetes resources are running and releases
the lease after deleting only the resources owned by this deployment.
"""

from __future__ import annotations

import json
import logging
import os
import signal
import subprocess
import sys
import time
import urllib.request
from pathlib import Path
from typing import Any


LOG = logging.getLogger("mthreads-1p1d-lease")
MCP_URL = os.getenv("GPU_BROKER_MCP_URL", "https://gpu-dashboard.devops.mthreads.com/mcp")
NODE = os.getenv("MTHREADS_DECODE_NODE", "10.20.36.18")
GPU_COUNT = int(os.getenv("MTHREADS_DECODE_GPUS", "8"))
POOL = os.getenv("GPU_BROKER_POOL", "开发资源池")
POLL_SECONDS = int(os.getenv("GPU_BROKER_POLL_SECONDS", "5"))
TTL_SECONDS = int(os.getenv("GPU_BROKER_TTL_SECONDS", "7200"))
RENEW_INTERVAL_SECONDS = int(os.getenv("GPU_BROKER_RENEW_INTERVAL_SECONDS", "60"))
EXPECTED_MINUTES = int(os.getenv("GPU_BROKER_EXPECTED_MINUTES", "120"))
OWNER = os.getenv("GPU_BROKER_OWNER", "llm-d-mt-watch")
TASK = os.getenv("GPU_BROKER_TASK", "DeepSeek-V4 1P1D TP8 validation")
NAMESPACE = os.getenv("LLM_D_NAMESPACE", "llm-d-mt")
KUBECTL = os.getenv("KUBECTL", "kubectl")
REPO_ROOT = Path(os.getenv("LLM_D_REPO_ROOT", Path(__file__).resolve().parents[1]))
OVERLAY = Path(
    os.getenv(
        "LLM_D_OVERLAY",
        REPO_ROOT
        / "guides/pd-disaggregation/modelserver/mthreads/vllm/multi-node-1p1d-tp8",
    )
)
STORE_OVERLAY = OVERLAY / "mooncake-master-store"
CLIENT_OVERLAY = OVERLAY / "mooncake-client"
CLEANUP_ON_STOP = os.getenv("LLM_D_CLEANUP_ON_STOP", "true").lower() in {
    "1",
    "true",
    "yes",
}
CHECK_ONLY = os.getenv("LLM_D_CHECK_ONLY", "false").lower() in {"1", "true", "yes"}

STOP = False


class BrokerError(RuntimeError):
    pass


def _find_key(value: Any, key: str) -> Any:
    if isinstance(value, dict):
        if key in value:
            return value[key]
        for child in value.values():
            found = _find_key(child, key)
            if found is not None:
                return found
    elif isinstance(value, list):
        for child in value:
            found = _find_key(child, key)
            if found is not None:
                return found
    return None


def _text(result: dict[str, Any]) -> str:
    return " ".join(
        item.get("text", "")
        for item in result.get("content", [])
        if item.get("type") == "text"
    )


def _rpc(method: str, params: dict[str, Any]) -> dict[str, Any]:
    body = json.dumps(
        {"jsonrpc": "2.0", "id": int(time.time_ns() % 2**31), "method": method, "params": params}
    ).encode()
    request = urllib.request.Request(
        MCP_URL,
        data=body,
        headers={
            "Accept": "application/json, text/event-stream",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = response.read().decode()
    except Exception as exc:  # pragma: no cover - network failure
        raise BrokerError(f"MCP request failed: {exc}") from exc

    for line in payload.splitlines():
        if not line.startswith("data: "):
            continue
        message = json.loads(line[6:])
        if "error" in message:
            raise BrokerError(str(message["error"]))
        return message["result"]
    raise BrokerError("MCP response did not contain an SSE data event")


def call_tool(name: str, arguments: dict[str, Any]) -> dict[str, Any]:
    result = _rpc("tools/call", {"name": name, "arguments": arguments})
    if result.get("isError"):
        raise BrokerError(_text(result) or f"broker tool {name} failed")
    return result


def target_has_gpus() -> bool:
    result = call_tool("gpu_status", {})
    structured = result.get("structuredContent", {})
    for server in structured.get("servers", []):
        if server.get("host") == NODE:
            free = server.get("free_gpu_indices", [])
            return int(server.get("gpu_free", len(free))) >= GPU_COUNT and len(free) >= GPU_COUNT
    LOG.warning("broker status did not list target node %s", NODE)
    return False


def acquire() -> tuple[str, str]:
    result = call_tool(
        "gpu_acquire",
        {
            "node": NODE,
            "gpus": GPU_COUNT,
            "pool": POOL,
            "wait": False,
            "owner": OWNER,
            "task": TASK,
            "ttl_seconds": TTL_SECONDS,
            "expected_minutes": EXPECTED_MINUTES,
        },
    )
    structured = result.get("structuredContent", {})
    lease_id = _find_key(structured, "lease_id")
    token = _find_key(structured, "token")
    if not lease_id or not token:
        raise BrokerError(_text(result) or "gpu_acquire returned no lease credentials")
    LOG.info("acquired lease %s on %s (%d GPUs)", lease_id, NODE, GPU_COUNT)
    return str(lease_id), str(token)


def renew(lease_id: str, token: str) -> None:
    result = call_tool(
        "gpu_renew",
        {
            "lease_id": lease_id,
            "token": token,
            "expected_minutes": EXPECTED_MINUTES,
        },
    )
    expires_at = _find_key(result.get("structuredContent", {}), "expires_at")
    LOG.info("renewed lease %s (expires_at=%s)", lease_id, expires_at)


def release(lease_id: str, token: str) -> None:
    try:
        call_tool("gpu_release", {"lease_id": lease_id, "token": token})
        LOG.info("released lease %s", lease_id)
    except BrokerError as exc:
        LOG.error("failed to release lease %s: %s", lease_id, exc)


def kubectl(*args: str) -> None:
    command = [KUBECTL, *args]
    LOG.info("running: %s", " ".join(command))
    subprocess.run(command, cwd=REPO_ROOT, check=True)


def apply_deployment() -> None:
    for path in (STORE_OVERLAY, CLIENT_OVERLAY, OVERLAY):
        if not path.exists():
            raise RuntimeError(f"overlay does not exist: {path}")
    kubectl("apply", "-k", str(STORE_OVERLAY))
    kubectl("apply", "-k", str(CLIENT_OVERLAY))
    kubectl("apply", "-n", NAMESPACE, "-k", str(OVERLAY))
    LOG.info("Mooncake and DeepSeek 1P1D manifests applied")


def cleanup_deployment() -> None:
    # Delete in reverse order; --ignore-not-found keeps stop/restart idempotent.
    for path, namespace in ((OVERLAY, NAMESPACE), (CLIENT_OVERLAY, None), (STORE_OVERLAY, None)):
        args = ["delete"]
        if namespace:
            args.extend(["-n", namespace])
        args.extend(["-k", str(path), "--ignore-not-found", "--wait=true"])
        try:
            kubectl(*args)
        except subprocess.CalledProcessError as exc:
            LOG.error("cleanup failed for %s: %s", path, exc)


def stop_handler(signum: int, _frame: Any) -> None:
    global STOP
    STOP = True
    LOG.info("received signal %s; stopping after current operation", signum)


def run() -> int:
    global STOP
    signal.signal(signal.SIGTERM, stop_handler)
    signal.signal(signal.SIGINT, stop_handler)

    if not OVERLAY.exists():
        LOG.error("overlay does not exist: %s", OVERLAY)
        return 2

    if CHECK_ONLY:
        available = target_has_gpus()
        LOG.info(
            "check-only: %s on %s (%d GPUs requested)",
            "available" if available else "not available",
            NODE,
            GPU_COUNT,
        )
        return 0 if available else 3

    lease_id = token = None
    deployment_started = False
    try:
        while not STOP:
            try:
                if target_has_gpus():
                    lease_id, token = acquire()
                    break
                LOG.info("waiting for %d free GPUs on %s", GPU_COUNT, NODE)
            except BrokerError as exc:
                LOG.warning("broker check/acquire failed: %s", exc)
            time.sleep(POLL_SECONDS)

        if STOP:
            return 0

        deployment_started = True
        apply_deployment()
        # The broker can cap the requested TTL; verify ownership frequently.
        renew_interval = max(30, min(RENEW_INTERVAL_SECONDS, TTL_SECONDS // 3))
        renew_at = time.monotonic() + renew_interval
        while not STOP:
            time.sleep(min(POLL_SECONDS, 30, max(1, renew_at - time.monotonic())))
            if time.monotonic() >= renew_at:
                renew(lease_id, token)
                renew_at = time.monotonic() + renew_interval
        return 0
    except (BrokerError, OSError, subprocess.CalledProcessError, RuntimeError) as exc:
        LOG.exception("lease/deployment service failed: %s", exc)
        return 1
    finally:
        if CLEANUP_ON_STOP and deployment_started:
            cleanup_deployment()
        if lease_id and token:
            release(lease_id, token)


if __name__ == "__main__":
    logging.basicConfig(
        level=os.getenv("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    sys.exit(run())
