# dl-test: handover for regression testing

Snapshot of 2026-11-15. dl-test is the AWS-hosted on-prem install used to test the installer end to end (Ascend + Defend on Argus v3).
It is a test environment: a few things below are deliberately partial, and the **Known limits** section says exactly which.

## 1. Where it is

| | |
|---|---|
| AWS account / region | `634319551745` (`s6rstage`), `us-east-2` |
| Cluster / namespace | EKS `dl-test`, namespace `straiker` |
| kubeconfig | `aws eks update-kubeconfig --name dl-test --region us-east-2 --profile s6rstage` (after `aws sso login --profile s6rstage`) |
| API gateway (SDK, agents) | `https://api.dltest.straiker.ai`: public, TLS (ACM certificate issued by the installer), answers `401` without a key. **Open to any address** (no source restriction yet). |
| Console, Defend, Ascend | reached through a port-forward (edge type `internal`, self-signed certificate): add the hosts to `/etc/hosts` (`127.0.0.1 app.straiker.internal defend.straiker.internal ascend.straiker.internal`), run `kubectl -n straiker port-forward svc/straiker-edge 8443:8443`, open `https://app.straiker.internal:8443/` |
| Sign-in | Amazon Cognito pool `us-east-2_oqY92P7q4`: email + password (first admin `prerna@straiker.ai`; password in Secrets Manager `dl-test/cognito/main-admin`), or **Sign in with SSO** (Google, for `straiker.ai`) |
| Email | SES domain `dltest.straiker.ai`, sandbox mode (only verified recipients) |

## 2. What is installed

| Component | Version | State |
|---|---|---|
| Console (frontend) | `onprem-v2026.11.8-rc3` (signed session cookie, RDS CA verified) | running |
| Platform services (foundation, registry, databridge, portico, grid) | `v2026.11.3` | running |
| API gateway | `v2.3.12` | running, internet-facing NLB with TLS |
| **Argus v3** (Defend engine) | image `v3-42f20012…` | 2 app pods + agent-config + compactor, running |
| Defend v1 (`straiker-defend`) | `onprem-v2026.8.24` | still running next to v3 (the console and Ascend graders use it) |
| **Ascend** (Iris) | `onprem-v2026.11.6.1` (Iris `main` + the on-prem commit, no Omada code) | control-plane, probe/recon/report workers running |
| ClickHouse | 25.8, 2 replicas + 3 Keeper | running; registry tables sync every minute (30 tables) |
| Kafka to ClickHouse (`straiker-ingest`) | Redpanda Connect 4.101.0 | running, **not yet proven with real traffic** |
| Data tier | Aurora PostgreSQL, MSK Serverless, ElastiCache, OpenSearch, DynamoDB, Secrets Manager | running |

**Model fleet (local vLLM on GPU nodes):**

| Model | Replicas now | Note |
|---|---|---|
| vision | 2/2 | image checks |
| wanda | 2/2 | image checks |
| kev-non-agentic (`kev-4b-19cat` v2) | 2/2 | classify mode answers (checked: 19 labels) |
| thanos | 1 (target 2) | Ascend's model; the old release is still in place |
| kev-agentic | **not installed** | needs one command (GPU quota is now approved at 160 vCPUs) |

Bedrock (`global.openai.gpt-5.6-sol` / `-terra`) answers in `us-east-2`; Argus v3's context reviewer uses it.

## 3. What Defend v3 can and cannot detect here

The model list is the one decided for on-prem (vision, wanda, kev-agentic, kev-non-agentic, thanos). An unavailable detector is reported by
the engine as unavailable, not as an error, so **regression expectations must treat these as off**:

| Detector | State |
|---|---|
| context-review (Bedrock), image-content, image-text | on |
| agentic-kev | off until kev-agentic is installed |
| text-classifier (the content classifier: antman, thor, quicksilver) | **unavailable by design**: those models are not deployed, and nothing in Argus calls `kev-4b-19cat` yet |
| prompt-kev | **unavailable by decision** (no prompt Kev on-prem) |
| judge, groundedness, insecure-output, topic-relevance | **unavailable by design** (they need the dropped models) |

## 4. How to check it

```bash
kubectl get pods -n straiker                        # everything should be 1/1 or Completed (39 ready at the snapshot)
DETECT_API_KEY=sk_agt_... scripts/smoke-test-detect.sh          # gateway: wrong key refused, real key gets a well-formed verdict
DETECT_API_KEY=sk_agt_... scripts/verify-clickhouse-ingest.sh   # Kafka -> ClickHouse: rows land in raw_event / raw_finding
```

Both scripts need an `sk_agt_` key: in the console create an agent, then mint a key for it (shown once).

## 5. Known limits (read before reporting a bug)

1. **Kafka to ClickHouse is built and wired but unproven.** `raw_event`, `raw_finding`, `audit_event` have 0 rows until traffic goes through Argus v3. The check script above proves it.
2. **Ascend still grades through Defend v1.** Moving it to v3 needs an `iris-grader` agent key (manual, console): see the runbook, "Ascend on Argus v3".
3. **`/api/v1/detect` through the gateway** is routed to `argus-service` (Argus v3), which serves `/api/v3/...` only. Likely a 404; use `/api/v3/detect`. Not yet checked with a real call.
4. **The gateway is open to every address.** Add `--gateway-allowed-cidrs` to restrict it.
5. **Kev-agentic and the second thanos replica are missing** until the full-fleet install is run (below).
6. **SSO:** the Google client secret was kept across installer re-runs; do a sign-in test.
7. **Email** is in the SES sandbox.
8. **Teardown leaves** the gateway's ACM certificate and Route53 records behind (delete by hand).
9. **Credentials to rotate** (shared in chat during setup): the `grid_cdc` Aurora password, the Cognito admin password, and the `s6rstage` test API key.
10. The Iris image was built by hand (the tag trigger needs a buildspec path fix in the infra repo).

## 6. How it was deployed, and how to change it

All with `scripts/install-straiker.sh` (state in `~/.straiker/install.json`; each phase is re-run only with `--rerun-phase`). Common flags used here:
`--data-layer --defend-engine v3 --inference-profile production --gateway-exposure public --gateway-domain api.dltest.straiker.ai`.

Finish the model fleet (kev-agentic, thanos replica 2), now that the quota is approved:

```bash
AWS_PROFILE=s6rstage AWS_REGION=us-east-2 scripts/install-straiker.sh --phase straiker-inference --rerun-phase --inference-profile production
```

Cost to keep in mind: the GPU nodes run about USD 8 per hour for the five model servers plus the thanos node; scale them down when idle.
Full detail on every phase, recovery and manual steps: `doc/data-layer-install-runbook.md`.
