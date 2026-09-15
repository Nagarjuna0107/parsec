"""Remote embedding client (PARSEC_EMBED_BACKEND=remote).

Calls an HTTP embedding service you operate that fronts the `bge-large-en-v1.5` encoder — the
same model the checkpoint was trained on. Use this when the encoder lives on a separate GPU box;
the `local` backend (local_embed.py) loads it in-process instead and needs no service.

Wire protocol: POST PARSEC_EMBED_URL with {"model_id", "texts"} -> {"vectors": [[...1024
f32...], ...]}. One batch per request, serially; the retry loop below rides a cold start.

PARSEC-PATCH: the reference client resolved a GPU pod via the Kubernetes API and hit a binary
endpoint; this copy posts JSON to a plain URL. Batching/retry semantics are unchanged.
"""

from __future__ import annotations

import json
import os
import time
import urllib.request
from collections.abc import Sequence

import numpy as np

# PARSEC-PATCH: JSON proxy endpoint replaces k8s pod discovery + binary /encode_bin.
EMBED_URL = os.environ.get("PARSEC_EMBED_URL", "")   # required for the remote backend
MODEL_ID = os.environ.get("PARSEC_EMBED_MODEL", "bge-large-en-v1.5")
# one batch per request, serially: the encoder is a single GPU that coalesces and runs one batch at
# a time, so concurrency buys ~1.2x and just adds JSON/transport pressure.
BATCH = int(os.environ.get("PARSEC_EMBED_BATCH", "512"))   # 512 amortizes the GPU better than 256 on
#                  long (~512-tok) chunks: ~134 vs ~92 texts/s. Throughput is sequence-length-bound
#                  (short texts hit ~1400/s); for full-length build chunks ~85-134 texts/s is GPU-bound.


class ParsecEmbedClient:
    """Thin client; same .embed(texts, as_query) surface as VertexClient."""

    def __init__(self, cfg: dict | None = None):
        self.cfg = cfg or {}
        emb = (self.cfg.get("models", {}) or {}).get("embedder", {}) or {}
        self.model_id = emb.get("model", MODEL_ID) if emb.get("backend") == "remote" else MODEL_ID
        if not EMBED_URL:
            raise RuntimeError("PARSEC_EMBED_BACKEND=remote requires PARSEC_EMBED_URL "
                               "(or use the in-process `local` backend)")

    def _embed_batch(self, texts: list[str]) -> np.ndarray:
        # PARSEC-PATCH: JSON /embed on the CPU proxy (embed-protocol §2a) — response
        # {"vectors": [[f32 x dim] ...], "model_id", "count", "token_count"}.
        body = json.dumps({"model_id": self.model_id, "texts": texts}).encode("utf-8")
        req = urllib.request.Request(EMBED_URL, data=body, method="POST")
        req.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(req, timeout=300) as r:     # generous: rides GPU cold-start/warm
            d = json.loads(r.read())
        return np.asarray(d["vectors"], dtype=np.float32).reshape(len(texts), -1)

    def _batch_with_retry(self, chunk: list[str]) -> np.ndarray:
        for attempt in range(7):
            try:
                return self._embed_batch(chunk)
            except Exception:
                if attempt == 6:
                    raise
                time.sleep(min(30.0, 2.0 ** attempt))            # ride scale-from-zero / load spikes
        raise RuntimeError("unreachable")

    def embed(self, texts: Sequence[str], as_query: bool = True, workers: int | None = None
              ) -> list[list[float]]:
        # One batch per request, serially (see BATCH note): the single-GPU encoder coalesces —
        # concurrency would only add load.
        texts = list(texts)
        out: list[list[float]] = []
        for i in range(0, len(texts), BATCH):
            out.extend(self._batch_with_retry(texts[i:i + BATCH]))   # extend with the f32 rows
        return out
