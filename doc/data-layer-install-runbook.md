# On-prem data-layer install: runbook

One command installs the whole AWS "data layer" deployment of Straiker (Ascend and Defend) into a customer or test
account. This is the handover document: what it builds, what has to exist first, how to run it, how to recover,
and what is still manual.

## 1. What it builds

Everything is created in **one AWS account and one region**.

| Layer | What | Notes |
|---|---|---|
| Network and cluster | VPC, EKS, Karpenter, EBS and EFS CSI drivers | `min` strategy: one AZ, one private `/24` |
| Images and models | ECR repos, S3 model bucket; image and model sync Jobs | copies from Straiker's artifact registry |
| Aurora PostgreSQL | **one** shared cluster, 17.x, port 3306, 2-16 ACU, writer + reader in two AZs | same settings as the SaaS clusters; all databases (platform services, frontend, iris, bifrost) |
| MSK Serverless, ElastiCache Serverless (TLS), EFS, DynamoDB, Secrets Manager | data services | models volume is EFS |
| ClickHouse | 1 shard x 2 replicas + 3-member Keeper | servers on the `straiker-clickhouse` pool (`r6g/r7g.2xlarge`) |
| Platform services | foundation, registry, databridge, portico, grid, api-gateway, ingest | grid's ClickHouse migrations run as Replicated tables |
| Products | frontend + dex + bifrost, 5 GPU inference models, Defend, Ascend | AI provider: Bedrock by default |
| Edge | Caddy with self-signed certificates (`--edge-type internal`) | reached with a port-forward |

Not included: WAF, monitoring/alerting, a custom domain or real certificates (see `--edge-type tailscale|alb`).

## 2. Before you run it

### On your machine
`aws`, `kubectl`, `helm`, `python3`, `curl`, and `crane` (`brew install crane`). OpenTofu is downloaded by the installer
if missing. Log in to AWS (`aws sso login --profile <profile>`) and confirm the account:
`aws sts get-caller-identity --profile <profile>`.

### In the AWS account
- Bedrock model access for `anthropic.claude-haiku-4-5-20251001-v1:0` and `anthropic.claude-sonnet-4-6`
  (Bedrock console > Model access; **console only, one time per account**). The installer's preflight blocks with a
  clear message if it is missing.
- Enough quota for the GPU instances (`g4dn.12xlarge` and `g5.2xlarge` on-demand vCPUs) and for ECR/Aurora/MSK.

### On Straiker's side (once per customer, once per release)
These live in the Straiker artifact account (631748089429, us-east-1) and are **not** done by the installer:

1. **Customer entry and key.** Add the customer under `customers` in
   `infra/live/artifact/tf/10_build/terragrunt.hcl` (tier `base` or `pro`), apply that stack (targeted, so the broker
   Lambda is left alone), and seed the customer's API key secret `onprem-cust-<name>` (see
   `infra/onprem/build/tf/customers.tf`). The customer email is `<name>@straiker.ai`. Give the key to whoever runs the
   install; treat it as a credential and rotate it after testing.
2. **Images published.** Every image the artifact chart pins must exist in `onprem-base`:
   - platform services (foundation, registry, databridge, grid, connect, portico, and each `-migrations`): push an
     `onprem-v<version>` tag on the `onprem/release` branch of `straiker-ai/platform` (CodeBuild `onprem-platform-build`
     builds it and publishes `v<version>`).
   - api-gateway: same, on branch `chore/onprem-release` of `straiker-ai/api-gateway` (`onprem-api-gateway-build`).
   - third-party images (including `clickhouse/clickhouse-server:25.8`): run the `onprem-mirror` CodeBuild project.
   Check with `aws ecr describe-images --repository-name onprem-base/straiker/<name> --image-ids imageTag=<tag>`
   in us-east-1.
3. If a tag in `charts/straiker-artifact/values.yaml` is bumped, the matching image must be published first.

## 3. Run it

```bash
scripts/install-data-layer.sh \
  --cluster-name <name> --region <region> --customer-name <customer> \
  --profile <aws-profile> --expect-account <account-id> \
  [--customer-key-file ./key.txt]
```

`--expect-account` refuses to run in the wrong account. `--check` runs the pre-flight only; `--status` shows the phase
status. The command prints what it is about to create and asks for confirmation (`--yes` skips that).

It runs `scripts/install-straiker.sh` through all phases and re-runs it while the only thing in the way is the image and
model sync Jobs finishing. It stops, with the installer's own message, when something needs a person. Phase state is
in `~/.straiker/install.json`: **re-running the same command resumes where it stopped**, and finished phases are skipped.

Questions on the first run only: the customer key (unless `--customer-key-file`), and the Bedrock region and inference
profile. Both are stored afterwards.

Expect about 1.5-2 hours. Cost while it runs is roughly 6-8 USD/hour, dominated by the GPU nodes.

### Open the product
```bash
echo '127.0.0.1  app.straiker.internal defend.straiker.internal ascend.straiker.internal' | sudo tee -a /etc/hosts
kubectl -n straiker port-forward svc/straiker-edge 8443:8443
# https://app.straiker.internal:8443/  (self-signed certificate)
kubectl get secret straiker-secrets -n straiker -o jsonpath='{.data.BOOTSTRAP_ADMIN_PASSWORD}' | base64 -d; echo
```
Log in as `admin@straiker.internal`, onboard a real admin, then disable the bootstrap login (see the installer's closing
message).

### Verify
`scripts/install-straiker.sh --data-layer --phase verify-data-layer --rerun-phase ...` (it is also the last data phase of the
run). It checks: EFS CSI driver, models PVC, ElastiCache over TLS, Aurora over TLS, ClickHouse replicas + Keeper +
no read-only replicas, and no failed Jobs. A passing run prints `All data-layer checks passed`.

## 4. Things the install handles for you (and how it fails if they ever break)

| Symptom | Cause | Handled by |
|---|---|---|
| `exec format error` on a pod | image in the mirror is amd64-only, nodes are arm64 (bifrost) | `MULTIARCH_OVERRIDES` copies the multi-arch upstream into your ECR after the sync |
| Pods `Pending`, Karpenter says "filtered out all instance types" | Karpenter cached an empty instance-type list for a node class created moments before | installer restarts the Karpenter controller when new node pools appear |
| `failed to assign an IP address to container`, EBS driver pod stuck | one `/24` private subnet exhausted by idle warm IPs | VPC CNI `WARM_IP_TARGET=2`, `MINIMUM_IP_TARGET=8` (eks Terraform) |
| ch-sync copies `0 tables`, "no encryption" | ClickHouse's libpq could not read `/root/.postgresql` and fell back to plain text | `HOME=/var/lib/clickhouse`, `PGSSLMODE=require` on the servers |
| grid migrations create non-replicated tables | ClickHouse 25.8 does not convert `MergeTree` DDL | init container rewrites engines to `Replicated*` (flag off by default, SaaS untouched) |
| Aurora engine not available | old default 16.x | installer picks the newest 17.x in the region |

## 5. Recovery

| Wrapper says | Do |
|---|---|
| `a phase needs attention: <message>` | fix what the message says, run the same command again |
| `the install failed` / installer error | read the output above it; fix; run the same command again |
| `still waiting after N minutes` | check `kubectl get jobs -n straiker`; run again (`--timeout-minutes` to wait longer) |
| `... belongs to cluster 'x'` | `~/.straiker/install.json` is from another install; move it aside |

Do not use `--rerun-phase` on `artifacts-sync` while its Jobs are running: it deletes and recreates them.
A `helm install` that timed out leaves a release in `failed`; running the same phase again upgrades it.

Teardown: `nuke-eks.sh` removes the cluster but **not** the data, artifacts and edge stacks. Turn off Aurora deletion
protection if the strategy was `ha`/`max`, then `tofu destroy` the data stack, delete the final snapshot
(`<cluster>-aurora-final`) by hand, and retry on `BucketNotEmpty`.

## 6. Known gaps and manual steps

- **Straiker-side prerequisites** in section 2 are manual (customer key, image tags, mirror run).
- **Bedrock model access** is console-only.
- **Private subnet size.** The `min` layout uses one `/24`. The CNI setting keeps it workable, but GPU plus ClickHouse
  nodes leave little headroom; use `ha` (more AZs) or bring your own larger subnets for anything bigger than a test.
- **Aurora port 3306** matches SaaS. Changing the port of an existing cluster restarts it and every consumer.
- **Bifrost database** is created but the bifrost chart does not use Postgres yet.
- **GPU sizing** starts on `g4dn.12xlarge` + `g5.2xlarge`; the SaaS regions use `g6e.4xlarge`. Upgrading is a node-pool change.
- **WAF, monitoring, ingress with real certificates** are not part of this install.
- **Edge**: `--edge-type internal` is a port-forward with self-signed certificates.
- Rotate the customer key after any test where it was pasted into a chat or a shell history.
