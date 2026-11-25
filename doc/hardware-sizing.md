# Straiker on-prem: hardware sizing for Ascend

For infrastructure and procurement teams planning an on-prem Ascend
(automated red-teaming) deployment.

**Light and Comprehensive assessments use the same footprint.** They differ in
duration (number of probes and conversation turns), not in hardware. More
throughput, or more assessments running at once, comes from adding worker and
attacker-model replicas.

These figures are a planning baseline. Final sizing depends on assessment
volume, concurrency, and how fast the target applications accept requests.

---

## GPU baseline

- **Attacker model:** 1× 48 GB-class GPU (e.g. NVIDIA L40S, A100, H100)
  - A quantized configuration for 24 GB GPUs (e.g. L4, A10G) is available,
    with half the context length (16k vs 32k tokens).
- **Detection model:** 1× 24 GB-class GPU (e.g. NVIDIA L4, A10G)
- **Agentic detection model (optional):** 1× 48 GB-class GPU (e.g. NVIDIA L40S)
  - Only needed when assessing agentic applications, to evaluate tool-call and
    action traces.
- **Total:** 2 GPUs baseline, 3 with agentic assessments.
- **Scaling:** add attacker-model replicas for more throughput or more
  concurrent assessments.

### Why the attacker runs unquantized by default

The 48 GB configuration runs the attacker in full bf16 precision. This is the
same configuration as Straiker's SaaS deployment, so on-prem results are
comparable. The quantized 24 GB tier depends on an extra vLLM quantization
plugin, is slower per request, and halves the context. Use it when only
24 GB GPUs are available.

---

## CPU, memory, and storage

| Component | Sizing |
| --- | --- |
| Platform services (non-GPU) | ~16 vCPU / 64 GB RAM across 2–3 nodes |
| Each GPU node | ~8 vCPU / 32 GB RAM |
| PostgreSQL volume | 20 GB to start |
| Search / index volume (OpenSearch) | 10 GB to start |
| Model-weight repository | ~100 GB |
| GPU node local disk (model cache) | ~200 GB per node |
| **Total storage** | **~500 GB**, growing with retention |

Assessment data is purged after 30 days by default
(`straiker-ascend`'s `cleanup.delayDays`).

---

## Bundled models

All models ship as container images and weights. Inference needs no internet
access at runtime.

| Model | Size | Role |
| --- | --- | --- |
| Attacker | 12B parameters, ~24 GB weights (bf16) | Generates adversarial prompts and multi-turn attacks |
| Detection classifier | 4B parameters, ~8 GB weights | Scores responses across 19 risk categories |
| Agentic detection classifier (optional) | 4B parameters, ~8 GB weights | Scores agent tool-call and action traces |

Weight sizes are estimated from parameter counts at bf16.

---

## Other dependencies

| Dependency | Notes |
| --- | --- |
| Kubernetes | All components ship as Helm charts |
| PostgreSQL 16 | Bundled (`straiker-system`), or bring your own |
| Valkey (Redis-compatible) | Bundled queue and cache |
| OpenSearch | Bundled search and archive index |
| Identity | Bundled OIDC broker (Dex), federating with your IdP (OIDC, SAML, LDAP) |
| LLM endpoint | An endpoint you approve, used for orchestration and evaluation. The installer supports your own OpenAI / Anthropic / xAI keys, AWS Bedrock, or a Straiker trial key (`--ai-provider-mode`) |

---

## Release status

This baseline describes the next-generation detection stack. The current
installer release runs the previous detection generation:

- Three 16 GB-class GPUs (e.g. T4) for the detection ensemble, in place of the
  single 24 GB detection GPU.
- The attacker defaults to the quantized 24 GB tier (`gpuProfile: g5`). Set
  `gpuProfile` to `g6e` or `a100` for the unquantized configuration.
