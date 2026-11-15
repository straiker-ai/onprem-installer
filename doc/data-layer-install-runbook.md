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
| Edge | **One internet-facing Application Load Balancer** (`--edge-type xalb`, the default): ACM certificates, TLS 1.2+, **AWS WAF**. Hosts `straiker.<domain>`, `straiker-defend.<domain>`, `straiker-ascend.<domain>` and the api-gateway `api.<domain>` | `terraform/aws/edge` (WAF, IAM, certificate) + AWS Load Balancer Controller; Caddy (`--edge-type internal`) is for offline tests only |

**AWS WAF** (`terraform/aws/edge/waf.tf`, Web ACL `<cluster>-edge`): AWS managed rule groups (IP reputation, Common, Known bad inputs), a
per-IP rate limit (`--waf-rate-limit`, default 10000 requests / 5 minutes, `0` = off), and per-host source allowlists:
`--internal-lb-source-ranges` for the console hosts, `--gateway-allowed-cidrs` for `api.<domain>`. Rules that inspect the **request body
count instead of block**: the Detect API receives attack prompts by design, and blocking them would break the product. Request logs go to
CloudWatch Logs `aws-waf-logs-<cluster>-edge` (30 days; `Authorization`, `Cookie` and `X-Api-Key` redacted).

**CloudWatch** (phase `observability`, `terraform/aws/observability`, the last phase):

| What | Where |
|---|---|
| Amazon CloudWatch Observability EKS add-on: Container Insights (enhanced) metrics for nodes, pods and GPUs (DCGM on the GPU nodes) | CloudWatch > Container Insights, cluster `<cluster>` |
| Every container's stdout/stderr (Fluent Bit), node and data-plane logs; 30-day retention | Logs `/aws/containerinsights/<cluster>/{application,dataplane,host,performance}` |
| EKS control-plane logs (audit, api, authenticator) | Logs `/aws/eks/<cluster>/cluster` |
| WAF request logs | Logs `aws-waf-logs-<cluster>-edge` |
| Alarms: failed nodes, node CPU > 85 %, node memory > 90 %, edge ALB 5xx (its own > 25, targets' > 50 per 5 min), each Aurora cluster's CPU > 80 % and capacity > 90 % of max ACUs | Alarms `<cluster>-*`, all to SNS topic `<cluster>-alarms` |

Application Signals is switched **off**: by default the add-on would inject an OpenTelemetry agent into every Java/Python
service on its next restart. `--alarm-email <address>` (repeatable) subscribes addresses to the topic: **MANUAL STEP**, each
address must click the link in AWS's "Subscription Confirmation" mail before it receives alarms. Thresholds and extra alarms:
`var.alarms` in `terraform/aws/observability` (a built-in alarm's key replaces it), then `--phase observability --rerun-phase`.

## 2. Before you run it

### On your machine
`aws`, `kubectl`, `helm`, `python3`, `curl`, and `crane` (`brew install crane`). OpenTofu is downloaded by the installer
if missing. Log in to AWS (`aws sso login --profile <profile>`) and confirm the account:
`aws sts get-caller-identity --profile <profile>`.

### In the AWS account
- Bedrock model access for `anthropic.claude-haiku-4-5-20251001-v1:0` and `anthropic.claude-sonnet-4-6`
  (Bedrock console > Model access; **console only, one time per account**). The installer's preflight blocks with a
  clear message if it is missing.
- **GPU quota, requested before the install** (a new account usually has 0-8 vCPUs, and the models cannot start without it).
  The fleet is 10 model servers, one GPU node each, so about **80 vCPUs** of "Running On-Demand G and VT instances"
  (quota code `L-DB2E81BA`, per region). Ask for **512 vCPUs** (Straiker's standard request; it leaves room for upgrades, extra replicas and larger GPU nodes):
  `aws service-quotas request-service-quota-increase --service-code ec2 --quota-code L-DB2E81BA --desired-value 512`
  (approval takes minutes to hours; check with `aws service-quotas get-service-quota ...`). The quota counts every
  G/VT instance already running in the account, so the installer subtracts those and stops in its first phase if too
  little is left. A100/H100 (p4d, p4de, p5) use a different quota, "Running On-Demand P instances" (`L-417A185B`),
  about 192 vCPUs for two p4d.24xlarge; those instance families are not enabled in the installer yet.
- **A domain** (`--domain customer.com`). The console hosts are `straiker.`, `straiker-defend.` and `straiker-ascend.<domain>`; the
  api-gateway is `api.<domain>` (change it with `--installer-arg --gateway-domain --installer-arg <name>`). With `--route53` (the domain's
  public zone is in this account) both certificates and every DNS record are automatic; `--domain` must then be the zone's own name. Otherwise
  pass `--certificate-arn` (an ISSUED ACM certificate in the cluster's region covering the three console hosts) and add the DNS records
  yourself (the console names as CNAMEs to the ALB). The api-gateway shares the ALB with the console; its certificate is issued by the
  installer from the domain:
  - the domain (or its parent) is a public **Route53 zone in the same account**: nothing else to do, the installer adds the DNS
    validation record, waits for the certificate, and points the name at the gateway. One command.
  - the domain's DNS is **elsewhere** (Cloudflare, an on-prem DNS server, a Route53 zone in a *different* AWS account): **MANUAL STEP**, two
    DNS records added by whoever manages that DNS. The installer prints the first (certificate validation) early, so it can be added
    while the rest installs, and the second (the gateway name, a CNAME to the load balancer) once the gateway exists. Both are written to
    `~/.straiker/gateway-dns-handoff-<cluster>.md`, a no-secrets sheet to send to the DNS admin. If the first record is not in place when
    the gateway is installed, that step stops with the record and continues on the next run. Only a public Route53 zone in the installer's
    own AWS account is automated.
  - **your own certificate**: `--gateway-cert-arn` (ISSUED, in the cluster's region); used as is. You add the DNS record for the name.
  - a private gateway needs none of this: `--gateway-exposure internal`.
  The installer's AWS identity needs `acm:RequestCertificate/DescribeCertificate/ListCertificates/ListTagsForCertificate/AddTagsToCertificate`,
  `route53:ListHostedZones/GetHostedZone/ChangeResourceRecordSets` and `elasticloadbalancing:DescribeLoadBalancers`.
  For the edge it also needs `wafv2:*` on the Web ACL and IP sets, and `logs:CreateLogGroup/PutRetentionPolicy/DeleteLogGroup/TagResource`
  plus `logs:CreateLogDelivery`/`logs:PutResourcePolicy`/`logs:DescribeResourcePolicies` for WAF logging.
- Quota for ECR, Aurora and MSK (the defaults are normally enough).

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
  --domain <customer.com> --route53 \
  --alarm-email <ops@customer.com> \
  [--customer-key-file ./key.txt]
```
Without the zone in this account: `--certificate-arn <arn>` instead of `--route53`. Questions asked on the first run also include
`--admin-email` (the first Cognito admin), passed with `--installer-arg --admin-email --installer-arg <address>`.

`--expect-account` refuses to run in the wrong account. `--check` runs the pre-flight only; `--status` shows the phase
status. The command prints what it is about to create and asks for confirmation (`--yes` skips that).

It runs `scripts/install-straiker.sh` through all phases and re-runs it while the only thing in the way is the image and
model sync Jobs finishing. It stops, with the installer's own message, when something needs a person. Phase state is
in `~/.straiker/install.json`: **re-running the same command resumes where it stopped**, and finished phases are skipped.

Questions on the first run only: the customer key (unless `--customer-key-file`), and the Bedrock region and inference
profile. Both are stored afterwards.

Expect about 1.5-2 hours. Cost while it runs is roughly 6-8 USD/hour, dominated by the GPU nodes.

### Open the product
`https://straiker.<domain>/` (the installer's access summary prints every URL, the WAF Web ACL and its log group). Sign in through
Cognito as the first admin (`--admin-email`; password in Secrets Manager `<cluster>/cognito/main-admin`). SDKs and agents use
`https://api.<domain>`.

With `--edge-type internal` (offline tests only) it is a port-forward with a self-signed certificate:
```bash
echo '127.0.0.1  app.straiker.internal defend.straiker.internal ascend.straiker.internal' | sudo tee -a /etc/hosts
kubectl -n straiker port-forward svc/straiker-edge 8443:8443
# https://app.straiker.internal:8443/
```

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
| `EC2 quota 'Running On-Demand G and VT instances' is N vCPUs ...` | request the increase (section 2), wait for approval, run the same command again. Without it Karpenter fails with `VcpuLimitExceeded` and the model pods stay Pending |
| `still waiting after N minutes` | check `kubectl get jobs -n straiker`; run again (`--timeout-minutes` to wait longer) |
| `... belongs to cluster 'x'` | `~/.straiker/install.json` is from another install; move it aside |

Do not use `--rerun-phase` on `artifacts-sync` while its Jobs are running: it deletes and recreates them.
A `helm install` that timed out leaves a release in `failed`; running the same phase again upgrades it.

Teardown: `nuke-eks.sh` removes the cluster but **not** the data, artifacts and edge stacks. Turn off Aurora deletion
protection if the strategy was `ha`/`max`, then `tofu destroy` the data stack, delete the final snapshot
(`<cluster>-aurora-final`) by hand, and retry on `BucketNotEmpty`.

## 6. Defend v3 (Argus v3): what it can detect, and Ascend on v3

Install with `--defend-engine v3`. The gateway sends `/api/v1/detect`, `/api/v3/detect` and the integration detect paths to
`argus-service` (Argus v3). `straiker-defend` (v1) still runs next to it: the console's `argusEndpoint` and, until the key
below exists, Ascend use it.

**What Defend v3 can and cannot detect** (the model fleet is vision, wanda, kev-agentic, kev-non-agentic, thanos; 2 replicas each):

| Detector | Needs | State on-prem |
|---|---|---|
| context-review | Bedrock (`global.openai.gpt-5.6-sol/-terra`) | on |
| image-content, image-text | wanda, vision | on |
| agentic-kev | kev-agentic | on once that model runs |
| text-classifier (the content classifier) | antman, thor, quicksilver | **unavailable**: not deployed, and nothing in Argus calls `kev-4b-19cat` yet |
| prompt-kev | a dedicated prompt Kev | **unavailable** by decision |
| judge, groundedness, insecure-output, topic-relevance | the other dropped models | **unavailable** |

An unavailable detector is reported as such by the engine, not as a failure. Regression expectations must treat those controls
as off.

**Smoke test:** `DETECT_API_KEY=sk_agt_... scripts/smoke-test-detect.sh` checks the gateway path (wrong key refused, real key
gets a well-formed verdict). The key is an agent key: in the console create an agent, then mint a key for it.

**Check that events reach ClickHouse:** `DETECT_API_KEY=sk_agt_... scripts/verify-clickhouse-ingest.sh` sends a few detect calls, waits,
and shows rows landing in `grid.raw_event` / `grid.raw_finding` plus each ingest stream's read / written / error / dead-letter
counts (from Redpanda Connect's metrics). It fails with the likely cause: nothing read = Argus did not publish to MSK; read but not
written = the ClickHouse insert fails. `audit_event` fills only from console activity (create or edit something, then
`--expect-audit`). Without the key it only observes.

**Ascend on Argus v3 (optional).** Iris's graders switch from v1 to `/api/v3/detect` only when two things exist: the endpoint
(set by the installer with `--defend-engine v3`) and an `sk_agt_` key of an agent named `iris-grader`, stored as
`ARGUS_V3_API_KEY` in `straiker-secrets`. Steps (manual: agent creation is a console step):
1. In the console create an agent named `iris-grader` (chat assistant) and mint an API key for it (shown once).
2. Re-run `--phase straiker-ascend --rerun-phase --defend-engine v3` with `ARGUS_V3_GRADER_KEY=sk_agt_...` in the environment.
3. Check `kubectl logs deploy/straiker-ascend-probe-worker` shows `argus_v3` requests and no 401s.
Until then Ascend keeps grading through v1, which is safe.

## 7. Known gaps and manual steps

- **Straiker-side prerequisites** in section 2 are manual (customer key, image tags, mirror run).
- **Bedrock model access** is console-only.
- **Private subnet size.** The `min` layout uses one `/24`. The CNI setting keeps it workable, but GPU plus ClickHouse
  nodes leave little headroom; use `ha` (more AZs) or bring your own larger subnets for anything bigger than a test.
- **Aurora port 3306** matches SaaS. Changing the port of an existing cluster restarts it and every consumer.
- **ClickHouse sync hardening rollout** (existing installs): run `--phase aws-data --rerun-phase` (adds the `grid_sync` password to Secrets Manager), then `--phase clickhouse --rerun-phase` (pods restart to pick up the user and the RDS CA), then `--phase ch-sync --rerun-phase`. If the sync then fails with a TLS error, the Aurora endpoint is reached under a name the certificate does not cover: set `postgresSslMode: require` on the clickhouse chart.
- **Gateway on the edge ALB.** With edge type `xalb` and `--gateway-exposure public` (both defaults), the api-gateway Service is ClusterIP
  and its own Ingress (`straiker-edge-xalb-api`, same IngressGroup, same ALB and WAF, health check on the actuator port 9090) carries
  `api.<domain>`; the installer points that name at the ALB in phase `straiker-edge`. ExternalDNS is told to leave this Ingress alone.
  **Moving an existing install off its gateway NLB** (e.g. dl-test): re-run phases `edge-infra`, `platform-services` and `straiker-edge`
  with `--edge-type xalb --custom-domain <domain>` and the same `--gateway-domain`. The Helm upgrade turns the Service into ClusterIP (the
  controller deletes the NLB) and the DNS record is rewritten to the ALB; expect a few minutes without the API in between.
  The ALB's security group is shared: when only one of `--internal-lb-source-ranges` / `--gateway-allowed-cidrs` is set, it stays open and
  WAF enforces the ranges per host.
- **Gateway exposure.** The api-gateway is internet-facing by default (`--gateway-exposure public`) and always over TLS: it needs
  `--gateway-domain` (certificate issued by the installer, see section 2; defaults to `api.<domain>` with edge type `xalb`) or
  `--gateway-cert-arn`, and the install stops early without one.
  Restrict who can connect with `--gateway-allowed-cidrs`. Ask for a private one with `--gateway-exposure internal` (internal load balancer,
  VPC only, plain HTTP inside the VPC) or `none` (in-cluster only). The installer checks the load balancer's scheme against the choice and
  blocks on a mismatch. Without the AWS Load Balancer Controller (edge type `internal`) the chart uses the cloud provider's own
  annotations. A load balancer's scheme cannot change in place: to switch an existing install, `kubectl delete svc api-gateway -n straiker`
  and re-run `--phase platform-services` with the exposure you want. The choice is remembered.
- **Gateway certificate and DNS records are not removed by teardown.** The ACM certificate (tagged `straiker:cluster=<name>`, free) and the
  Route53 records the installer wrote stay behind: delete them by hand after an uninstall. The TLS-on-the-load-balancer path without the AWS
  Load Balancer Controller (in-tree NLB with a certificate) has been rendered and tested offline only; check it on the first real install.
- **Bifrost database** is created but the bifrost chart does not use Postgres yet.
- **GPU sizing** starts on `g4dn.12xlarge` + `g5.2xlarge`; the SaaS regions use `g6e.4xlarge`. Upgrading is a node-pool change.
- **Dashboards and tracing** (Grafana, OpenTelemetry, Argo CD from the reference architecture) are not part of this install; CloudWatch
  covers metrics, logs and alarms. Re-run `--phase observability --rerun-phase` after changing the edge (the ALB alarms follow the
  ALB) or adding an Aurora cluster.
- **Existing installs** get CloudWatch with `--phase observability`; log groups the agent created earlier and a hand-installed add-on
  are adopted, not recreated. The cluster needs the `eks-pod-identity-agent` add-on (the phase stops with the command if it is missing).
- **WAF tuning**: body rules only count. Review the counted matches in the WAF log after the first real traffic and decide per rule;
  change them in `terraform/aws/edge` (`waf_managed_rule_groups`), then `--phase edge-infra --rerun-phase`.
- **Edge**: `--edge-type internal` is a port-forward with self-signed certificates, for offline tests only.
- Rotate the customer key after any test where it was pasted into a chat or a shell history.
