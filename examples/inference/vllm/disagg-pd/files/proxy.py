"""Prefill-then-decode proxy for vLLM disaggregated serving with NixlConnector.

For each /v1/completions or /v1/chat/completions request:

1. Send it to one prefill engine as a non-streaming request for a single
   token, with ``kv_transfer_params = {"do_remote_decode": true, ...}``, so
   the prefill engine computes the KV cache and keeps it for a remote reader.
2. Take the ``kv_transfer_params`` from the prefill response (they name the
   prefill engine, its NIXL handshake address and the KV blocks) and send
   the original request with them to one decode engine, which pulls the KV
   cache over NIXL and generates the answer.
3. Stream the decode response back to the client unchanged.

This is the flow of vLLM's own NixlConnector integration test proxy
(tests/v1/kv_connector/nixl_integration/toy_proxy_server.py). Engines are
found by resolving the headless prefill and decode Services, which list only
ready pods, and are picked round robin per request.

Runs in the vLLM image: fastapi, uvicorn and httpx are vLLM dependencies.
"""

import asyncio
import itertools
import logging
import os
import socket
import time
import uuid

import httpx
import uvicorn
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response, StreamingResponse
from starlette.background import BackgroundTask

PREFILL_HOST = os.environ["PREFILL_HOST"]
DECODE_HOST = os.environ["DECODE_HOST"]
ENGINE_PORT = int(os.environ["ENGINE_PORT"])
PORT = int(os.environ.get("PORT", "8000"))
RESOLVE_INTERVAL_S = float(os.environ.get("RESOLVE_INTERVAL_SECONDS", "5"))

# Request fields a prefill-only request must not carry: it produces one token.
PREFILL_DROP = ("stream_options", "min_tokens", "min_completion_tokens")
FORWARD_HEADERS = ("authorization",)

log = logging.getLogger("disagg-proxy")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
# One log line per request would cost more than the proxying itself under load.
logging.getLogger("httpx").setLevel(logging.WARNING)


class Pool:
    """Round robin over the addresses a headless Service resolves to."""

    def __init__(self, host: str) -> None:
        self.host = host
        self.addrs: list[str] = []
        self.cycle = iter(())
        self.resolved_at = 0.0
        self.lock = asyncio.Lock()

    async def refresh(self) -> None:
        async with self.lock:
            if time.monotonic() - self.resolved_at < RESOLVE_INTERVAL_S:
                return
            try:
                infos = await asyncio.get_running_loop().getaddrinfo(
                    self.host, ENGINE_PORT, type=socket.SOCK_STREAM
                )
                addrs = sorted({info[4][0] for info in infos})
            except socket.gaierror:
                addrs = []
            if addrs != self.addrs:
                log.info("%s -> %s", self.host, addrs)
                self.addrs = addrs
                self.cycle = itertools.cycle(addrs)
            self.resolved_at = time.monotonic()

    async def next_url(self) -> str | None:
        await self.refresh()
        if not self.addrs:
            return None
        addr = next(self.cycle)
        host = f"[{addr}]" if ":" in addr else addr
        return f"http://{host}:{ENGINE_PORT}"


prefill = Pool(PREFILL_HOST)
decode = Pool(DECODE_HOST)
client = httpx.AsyncClient(
    timeout=httpx.Timeout(None, connect=10.0),
    limits=httpx.Limits(max_connections=None, max_keepalive_connections=None),
)
app = FastAPI()


def unavailable(role: str) -> JSONResponse:
    return JSONResponse({"error": f"no ready {role} engine"}, status_code=503)


def upstream_error(role: str, resp: httpx.Response, body: bytes) -> Response:
    log.warning("%s returned %s", role, resp.status_code)
    return Response(
        content=body,
        status_code=resp.status_code,
        media_type=resp.headers.get("content-type", "application/json"),
    )


async def disaggregated(api: str, request: Request) -> Response:
    body = await request.json()
    request_id = request.headers.get("x-request-id") or str(uuid.uuid4())
    headers = {"X-Request-Id": request_id}
    for name in FORWARD_HEADERS:
        if name in request.headers:
            headers[name] = request.headers[name]

    prefill_url = await prefill.next_url()
    if prefill_url is None:
        return unavailable("prefill")
    first = {k: v for k, v in body.items() if k not in PREFILL_DROP}
    first.update(
        stream=False,
        max_tokens=1,
        kv_transfer_params={
            "do_remote_decode": True,
            "do_remote_prefill": False,
            "remote_engine_id": None,
            "remote_block_ids": None,
            "remote_host": None,
            "remote_port": None,
        },
    )
    if "max_completion_tokens" in first:
        first["max_completion_tokens"] = 1
    try:
        resp = await client.post(prefill_url + api, json=first, headers=headers)
    except httpx.HTTPError as e:
        log.warning("prefill request failed: %s", e)
        return JSONResponse({"error": "prefill engine unreachable"}, status_code=502)
    if resp.status_code != 200:
        return upstream_error("prefill", resp, resp.content)
    try:
        params = resp.json().get("kv_transfer_params")
    except ValueError:
        return JSONResponse({"error": "prefill response is not JSON"}, status_code=502)
    if not params:
        # Without them decode would quietly run the prefill itself, and the
        # request would look served while no KV cache moved.
        return JSONResponse(
            {"error": "prefill response carries no kv_transfer_params"}, status_code=502
        )
    body["kv_transfer_params"] = params

    decode_url = await decode.next_url()
    if decode_url is None:
        return unavailable("decode")
    try:
        upstream = await client.send(
            client.build_request("POST", decode_url + api, json=body, headers=headers),
            stream=True,
        )
    except httpx.HTTPError as e:
        log.warning("decode request failed: %s", e)
        return JSONResponse({"error": "decode engine unreachable"}, status_code=502)
    if upstream.status_code != 200:
        content = await upstream.aread()
        await upstream.aclose()
        return upstream_error("decode", upstream, content)
    return StreamingResponse(
        upstream.aiter_raw(),
        status_code=200,
        media_type=upstream.headers.get("content-type"),
        background=BackgroundTask(upstream.aclose),
    )


@app.post("/v1/completions")
async def completions(request: Request) -> Response:
    return await disaggregated("/v1/completions", request)


@app.post("/v1/chat/completions")
async def chat_completions(request: Request) -> Response:
    return await disaggregated("/v1/chat/completions", request)


@app.get("/v1/models")
async def models() -> Response:
    url = await decode.next_url()
    if url is None:
        return unavailable("decode")
    resp = await client.get(url + "/v1/models")
    return Response(resp.content, status_code=resp.status_code, media_type="application/json")


@app.get("/health")
async def health() -> JSONResponse:
    """Ready only when at least one prefill and one decode engine are ready."""
    await prefill.refresh()
    await decode.refresh()
    status = {"prefill_engines": len(prefill.addrs), "decode_engines": len(decode.addrs)}
    ok = prefill.addrs and decode.addrs
    return JSONResponse(status, status_code=200 if ok else 503)


if __name__ == "__main__":
    # 0.0.0.0 inside the pod network namespace, so the ClusterIP Service can
    # reach it; the Service is the boundary, not this address.
    uvicorn.run(app, host="0.0.0.0", port=PORT, log_level="info", access_log=False)  # noqa: S104
