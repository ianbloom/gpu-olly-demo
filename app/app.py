"""
GPU Inference Demo Service
Simulates an LLM inference workload on NVIDIA GPUs using PyTorch.

Telemetry:
  - OpenLIT SDK: GPU stats + GenAI semantic-convention spans/metrics via OTLP
  - Grafana Sigil SDK: structured LLM generation records (input/output messages,
    token usage, latency) sent to Grafana AI Observability
  - Both use OTEL_EXPORTER_OTLP_ENDPOINT / OTEL_EXPORTER_OTLP_HEADERS for traces/metrics
"""
import os
import uuid
import time
import random
import asyncio
import logging
from contextlib import asynccontextmanager

import base64
import httpx
import openlit
from datetime import datetime, timezone
from opentelemetry.trace import format_trace_id, format_span_id

import torch
import uvicorn
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from opentelemetry import trace, metrics

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

SERVICE_NAME = os.getenv("SERVICE_NAME", "gpu-inference-demo")
MODEL_NAME   = os.getenv("MODEL_NAME", "demo-llm-7b")

# ── OpenLIT — GPU stats + GenAI OTel instrumentation ──────────────────────────
openlit.init(
    collect_gpu_stats=True,
    environment="production",
    application_name=SERVICE_NAME,
)

# ── Sigil — direct HTTP to Generation Ingest API ──────────────────────────────
_sigil_endpoint  = os.getenv("SIGIL_ENDPOINT", "").rstrip("/")
_sigil_tenant_id = os.getenv("SIGIL_AUTH_TENANT_ID", "")
_sigil_token     = os.getenv("SIGIL_AUTH_TOKEN", "")

if _sigil_endpoint and _sigil_tenant_id and _sigil_token:
    _sigil_auth = base64.b64encode(
        f"{_sigil_tenant_id}:{_sigil_token}".encode()
    ).decode()
    _sigil_headers = {
        "Authorization": f"Basic {_sigil_auth}",
        "X-Scope-OrgID": _sigil_tenant_id,
        "Content-Type":  "application/json",
    }
    _sigil_url = f"{_sigil_endpoint}/api/v1/generations:export"
    logger.info("Sigil generation ingest configured: %s", _sigil_url)
else:
    _sigil_url     = ""
    _sigil_headers = {}
    logger.warning(
        "Sigil not configured (SIGIL_ENDPOINT / SIGIL_AUTH_TENANT_ID / "
        "SIGIL_AUTH_TOKEN not set) — generation telemetry disabled"
    )


async def export_generation(payload: dict) -> None:
    """Fire-and-forget POST to the Sigil generation ingest API."""
    try:
        async with httpx.AsyncClient(timeout=5) as client:
            resp = await client.post(_sigil_url, json=payload, headers=_sigil_headers)
        if resp.status_code not in (200, 202):
            logger.warning("Sigil export failed: %s %s", resp.status_code, resp.text[:200])
        else:
            logger.debug("Sigil export accepted: %s", resp.text[:100])
    except Exception as exc:
        logger.warning("Sigil export error: %s", exc)

# ── OTel tracer + meter (providers configured by OpenLIT above) ───────────────
tracer = trace.get_tracer(__name__)
meter  = metrics.get_meter(__name__)

# LLM-style metrics (OpenTelemetry GenAI semantic conventions)
request_counter  = meter.create_counter("gen_ai.requests",           unit="requests")
token_counter    = meter.create_counter("gen_ai.tokens",             unit="tokens")
request_duration = meter.create_histogram("gen_ai.request.duration", unit="ms")

# ── GPU setup ─────────────────────────────────────────────────────────────────
DEVICE        = torch.device("cuda" if torch.cuda.is_available() else "cpu")
GPU_AVAILABLE = torch.cuda.is_available()

def warmup_gpu():
    if GPU_AVAILABLE:
        x = torch.randn(512, 512, device=DEVICE)
        _ = torch.matmul(x, x)
        torch.cuda.synchronize()
        logger.info("GPU warmed up: %s", torch.cuda.get_device_name(0))
    else:
        logger.warning("No GPU detected – running on CPU (metrics will still emit)")

@asynccontextmanager
async def lifespan(app: FastAPI):
    warmup_gpu()
    yield
    if GPU_AVAILABLE:
        torch.cuda.empty_cache()

app = FastAPI(title="GPU Inference Demo", lifespan=lifespan)

# ── Fake vocabulary for synthetic completions ─────────────────────────────────
VOCAB = [
    "the", "model", "predicts", "that", "neural", "networks", "learn",
    "representations", "of", "data", "using", "gradient", "descent",
    "and", "backpropagation", "to", "minimize", "loss", "functions",
    "transformers", "use", "attention", "mechanisms", "for", "sequence",
    "modeling", "with", "remarkable", "efficiency", "on", "GPU", "hardware",
]

def generate_completion(prompt: str, max_tokens: int) -> tuple[str, int]:
    n_tokens = random.randint(max(1, max_tokens // 2), max_tokens)
    return " ".join(random.choices(VOCAB, k=n_tokens)) + ".", n_tokens

def simulate_gpu_inference(batch_size: int, seq_len: int, hidden_dim: int = 2048):
    start = time.perf_counter()
    with torch.no_grad():
        q = torch.randn(batch_size, seq_len, hidden_dim, device=DEVICE)
        k = torch.randn(batch_size, seq_len, hidden_dim, device=DEVICE)
        v = torch.randn(batch_size, seq_len, hidden_dim, device=DEVICE)
        scores = torch.bmm(q, k.transpose(1, 2)) / (hidden_dim ** 0.5)
        attn   = torch.softmax(scores, dim=-1)
        out    = torch.bmm(attn, v)
        w1 = torch.randn(hidden_dim, hidden_dim * 4, device=DEVICE)
        w2 = torch.randn(hidden_dim * 4, hidden_dim, device=DEVICE)
        ffn = torch.relu(out @ w1) @ w2
        if GPU_AVAILABLE:
            torch.cuda.synchronize()
    return (time.perf_counter() - start) * 1000, ffn

# ── Request / response models ─────────────────────────────────────────────────
class GenerateRequest(BaseModel):
    prompt: str
    max_tokens: int = 256
    temperature: float = 0.7
    conversation_id: str = ""   # optional — groups turns in Sigil

class GenerateResponse(BaseModel):
    completion: str
    prompt_tokens: int
    completion_tokens: int
    total_tokens: int
    latency_ms: float
    model: str
    device: str

# ── Routes ────────────────────────────────────────────────────────────────────
@app.get("/healthz")
async def healthz():
    return {"status": "ok", "gpu": GPU_AVAILABLE, "device": str(DEVICE)}

@app.get("/metrics/gpu")
async def gpu_metrics():
    if not GPU_AVAILABLE:
        return {"gpu": False}
    return {
        "device":          torch.cuda.get_device_name(0),
        "memory_used_mb":  torch.cuda.memory_allocated(0) / 1e6,
        "memory_total_mb": torch.cuda.get_device_properties(0).total_memory / 1e6,
    }

@app.post("/generate", response_model=GenerateResponse)
async def generate(req: GenerateRequest):
    if not req.prompt.strip():
        raise HTTPException(status_code=400, detail="prompt must not be empty")

    prompt_tokens   = len(req.prompt.split())
    seq_len         = min(prompt_tokens + req.max_tokens, 512)
    conversation_id = req.conversation_id or str(uuid.uuid4())
    generation_id   = str(uuid.uuid4())
    gen_start_dt    = datetime.now(timezone.utc)

    with tracer.start_as_current_span("llm.generate") as span:
        span.set_attribute("gen_ai.system",              "demo-llm")
        span.set_attribute("gen_ai.request.model",       MODEL_NAME)
        span.set_attribute("gen_ai.request.max_tokens",  req.max_tokens)
        span.set_attribute("gen_ai.request.temperature", req.temperature)
        span.set_attribute("llm.prompt_tokens",          prompt_tokens)

        latency_ms, _ = await asyncio.get_event_loop().run_in_executor(
            None, simulate_gpu_inference, 1, seq_len
        )
        gen_end_dt = datetime.now(timezone.utc)

        completion, completion_tokens = generate_completion(req.prompt, req.max_tokens)
        total_tokens = prompt_tokens + completion_tokens

        span.set_attribute("gen_ai.usage.prompt_tokens",     prompt_tokens)
        span.set_attribute("gen_ai.usage.completion_tokens", completion_tokens)
        span.set_attribute("gen_ai.response.model",          MODEL_NAME)

        request_counter.add(1,               {"model": MODEL_NAME, "status": "success"})
        token_counter.add(prompt_tokens,     {"model": MODEL_NAME, "type": "prompt"})
        token_counter.add(completion_tokens, {"model": MODEL_NAME, "type": "completion"})
        request_duration.record(latency_ms,  {"model": MODEL_NAME})

        # ── Sigil generation record ────────────────────────────────────────────
        if _sigil_url:
            span_ctx = span.get_span_context()
            asyncio.ensure_future(export_generation({
                "generations": [{
                    "id":              generation_id,
                    "conversation_id": conversation_id,
                    "agent_name":      SERVICE_NAME,
                    "agent_version":   "1.0.0",
                    "mode":            "SYNC",
                    "model":           {"provider": "demo", "name": MODEL_NAME},
                    "trace_id":        format_trace_id(span_ctx.trace_id),
                    "span_id":         format_span_id(span_ctx.span_id),
                    "input":  [{"role": "user",      "parts": [{"text": req.prompt}]}],
                    "output": [{"role": "assistant",  "parts": [{"text": completion}]}],
                    "usage": {
                        "input_tokens":  prompt_tokens,
                        "output_tokens": completion_tokens,
                    },
                    "stop_reason":  "stop",
                    "started_at":   gen_start_dt.isoformat(),
                    "completed_at": gen_end_dt.isoformat(),
                }]
            }))

    return GenerateResponse(
        completion=completion,
        prompt_tokens=prompt_tokens,
        completion_tokens=completion_tokens,
        total_tokens=total_tokens,
        latency_ms=round(latency_ms, 2),
        model=MODEL_NAME,
        device=str(DEVICE),
    )

if __name__ == "__main__":
    uvicorn.run("app:app", host="0.0.0.0", port=8080, workers=1)
