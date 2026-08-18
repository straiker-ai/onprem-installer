# Third-Party Software Notices and Information

This document lists the third-party open-source software included or referenced
by the Straiker on-premises Helm charts in this repository (`charts/straiker-system`,
`charts/straiker-artifact`, `charts/straiker-core`, `charts/straiker-inference`,
`charts/straiker-defend`, `charts/straiker-edge`), plus the infrastructure tooling
`scripts/install-straiker.sh` installs directly (Karpenter and its GKE community
provider). All third-party images are mirrored into the customer's own ECR/Artifact
Registry by `charts/straiker-artifact`'s image-mirror Job — Straiker does not
redistribute these images itself.

If you are conducting a procurement or compliance review, this is the
authoritative inventory.

---

## charts/straiker-system

| Component | Version | Image / Chart | License | Upstream |
|---|---|---|---|---|
| NVIDIA k8s-device-plugin | v0.17.0 | `nvidia/k8s-device-plugin` | Apache-2.0 | https://github.com/NVIDIA/k8s-device-plugin |
| OpenSearch | 3.6.0 | `opensearchproject/opensearch` (image) + `opensearch-project/opensearch` (Helm chart dependency) | Apache-2.0 | https://github.com/opensearch-project/OpenSearch |
| PostgreSQL | 16-alpine | `library/postgres` | PostgreSQL License (permissive, BSD-style) | https://github.com/postgres/postgres |
| Valkey | 8-alpine | `valkey/valkey` | BSD-3-Clause | https://github.com/valkey-io/valkey |
| Redpanda Connect | 4.101.0 | `redpandadata/connect` | Dual: Apache-2.0 (most connectors) + RCL — Redpanda Community License (enterprise-only features) | https://github.com/redpanda-data/connect |

**Valkey:** Linux Foundation fork of Redis, BSD-3-Clause licensed. Used in
place of `redis:7-alpine` to avoid the SSPL/RSALv2 license that ships with
Redis 7.4+.

**Redpanda Connect:** the distributed image bundles both license paths; they
cannot be separated at the image level. `charts/straiker-system`'s own
pipeline (`templates/benthos.yaml`) only uses the `http_server` input and
`opensearch` output, both covered by the Apache-2.0 portion, but the image
itself is dual-licensed regardless of which connectors are actually invoked
at runtime. Verified directly against the project's own `licenses/README.md`.

---

## charts/straiker-artifact

| Component | Version | Image | License | Upstream |
|---|---|---|---|---|
| rclone | 1.68 | `rclone/rclone` | MIT | https://github.com/rclone/rclone |
| crane (go-containerregistry) | latest | `gcr.io/go-containerregistry/crane` | Apache-2.0 | https://github.com/google/go-containerregistry |

Both are Straiker's own tooling images for mirroring container images and
model artifacts into the customer's cloud account — not part of the
customer-facing application, but bundled/pulled the same way.

---

## charts/straiker-core

| Component | Version | Image | License | Upstream |
|---|---|---|---|---|
| dex | v2.45.1 | `dexidp/dex` | Apache-2.0 | https://github.com/dexidp/dex |
| Caddy | 2-alpine | `library/caddy` | Apache-2.0 | https://github.com/caddyserver/caddy |
| Bifrost | v1.6.7 | `maximhq/bifrost` | Apache-2.0 | https://github.com/maximhq/bifrost |

### Straiker proprietary images (not open-source)

`straiker/frontend`, `straiker/frontend-migrate` — Straiker's own application
and its schema-migration counterpart. Mirrored from Straiker's build pipeline
into the customer's own ECR/Artifact Registry; there is no Straiker-hosted
mirror in the customer's cluster.

---

## charts/straiker-inference

| Component | Version | Image | License | Upstream |
|---|---|---|---|---|
| vLLM | v0.27.0 | `straiker/vllm` (Straiker-built, from upstream) | Apache-2.0 (upstream project) | https://github.com/vllm-project/vllm |
| AWS CLI | 2.24.24 / 2.17.62 | `public.ecr.aws/aws-cli/aws-cli` | Apache-2.0 | https://github.com/aws/aws-cli |
| Google Cloud SDK | 531.0.0-slim | `gcr.io/google.com/cloudsdktool/cloud-sdk` | Apache-2.0 (Google Cloud client components; distributed as part of Google's own Cloud SDK toolkit) | https://github.com/GoogleCloudPlatform/cloud-sdk-docker |

One of the AWS CLI / Google Cloud SDK images (selected per `cloudProvider`) is
used by the model-sync init containers that copy model weights from
`global.modelBucket` (S3/GCS) into each inference pod. The same two images are
also used by `charts/straiker-defend`'s tokenizer-pull init container, and by
`charts/straiker-artifact`'s image-mirror Job on GKE.

---

## charts/straiker-defend

`straiker/argus` — Straiker proprietary, not open-source. Mirrored the same
way as `straiker/frontend` above. Its tokenizer-pull init container reuses
the AWS CLI / Google Cloud SDK images listed under straiker-inference above.

---

## Installer-managed infrastructure (not a Helm chart)

`scripts/install-straiker.sh` installs these directly via Helm, outside any
chart in this repository:

| Component | Version | Chart source | License | Upstream |
|---|---|---|---|---|
| Karpenter | v1.14.0 (pinned in script) | `oci://public.ecr.aws/karpenter/karpenter` | Apache-2.0 | https://github.com/kubernetes-sigs/karpenter |
| karpenter-provider-gcp | 0.6.0 (pinned in script) | `https://cloudpilot-ai.github.io/karpenter-provider-gcp` (community project, not Google-official) | Apache-2.0 | https://github.com/cloudpilot-ai/karpenter-provider-gcp |

---

## Summary by license

- **Apache-2.0:** NVIDIA k8s-device-plugin, OpenSearch, crane/go-containerregistry,
  dex, Caddy, Bifrost, vLLM (upstream), AWS CLI, Google Cloud SDK, Karpenter,
  karpenter-provider-gcp, and the Apache-2.0-covered majority of Redpanda Connect.
- **MIT:** rclone.
- **BSD-3-Clause:** Valkey.
- **PostgreSQL License (permissive, BSD-style):** PostgreSQL.
- **RCL — Redpanda Community License (source-available, not OSI-approved):**
  the enterprise-only portion of Redpanda Connect's codebase, bundled into the
  same image as its Apache-2.0 portion. Only the Apache-2.0-covered
  `http_server` input and `opensearch` output connectors are actually used by
  this repo's pipeline.

---

## Reporting issues

If you believe a component is missing from this list or the license
information is incorrect, please contact Straiker support.
