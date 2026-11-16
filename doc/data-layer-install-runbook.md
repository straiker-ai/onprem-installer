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
| Products | frontend + dex + bifrost, 5 GPU inference models (x2 replicas), Defend, Ascend | AI provider: Bedrock by default |
| GPU nodes | customers: **2 x p4d.24xlarge** (pool grows to 4, never expired by age); test installs: one g5/g6e-class node per model server (`--gpu-fleet per-model`) | see "GPU fleet" in section 2 |
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

### AWS access: the credentials the installer runs with
The installer has no AWS login of its own. It runs the standard AWS CLI, OpenTofu, kubectl and Helm against whatever credentials
the shell already has, so the customer must give the AWS CLI working credentials first. It never stores them (the state file in
`~/.straiker` keeps only the profile name).

- Pick the account with `--aws-profile <name>` (exported as `AWS_PROFILE` for every command), or the `AWS_PROFILE` environment
  variable. With neither, it asks for a profile (blank = the default credential chain). The region comes from `--aws-region`.
- Any way of giving the CLI credentials works: IAM Identity Center (`aws configure sso`, then `aws sso login --profile <name>`),
  static keys (`aws configure --profile <name>` or `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_SESSION_TOKEN`), an assumed
  role (a profile with `role_arn` and `source_profile`), or an instance/CloudShell role.
- Prove it before the install: `aws sts get-caller-identity --profile <name>` must print the customer's account ID.
- The login must last the whole run (about 2-3 hours): a short SSO session expires mid-install.
- The role needs to create IAM roles and service-linked roles, VPC, EKS, MSK, Aurora, OpenSearch, ElastiCache, EFS, WAF, ACM
  and SES resources; check that no service control policy (SCP) blocks them. Missing IAM-role creation is the most common gap.

### In the AWS account
- Bedrock model access for `anthropic.claude-haiku-4-5-20251001-v1:0` and `anthropic.claude-sonnet-4-6`
  (Bedrock console > Model access; **console only, one time per account**). The installer's preflight blocks with a
  clear message if it is missing.
- **GPU fleet and its quota, requested before the install** (a new account usually has 0-8 vCPUs, and the models cannot
  start without it). The fleet is 10 model servers (5 models x 2 replicas), one GPU each. Two shapes (`--gpu-fleet`,
  remembered):

  | `--gpu-fleet` | For | Nodes | EC2 quota (per region) | Ask for |
  |---|---|---|---|---|
  | **`p4d`** (default for a new install) | **customers** (the reference architecture) | `p4d.24xlarge` (8x A100 40 GB, 96 vCPU): **2 nodes** for the fleet, the pool grows to `--gpu-max-nodes` (default **4**) | "Running On-Demand P instances", `L-417A185B`: 96 vCPUs per node | **384 vCPUs** (4 nodes) |
  | `per-model` | Straiker test installs (dl-test) | one `g4dn/g5/g6/g6e` node per server, each model's validated tier | "Running On-Demand G and VT instances", `L-DB2E81BA` | 512 vCPUs |

  **`--gpu-instance-type`** overrides which EC2 type the `p4d` (packed) fleet is pinned to, same "one server per GPU,
  one pinned type" shape either way — a stand-in while A100/p4d capacity is being arranged, not a cost optimization.
  Known types today: `p4d.24xlarge`/`p4de.24xlarge`/`p5.48xlarge` (P-instance quota) and `g6e.4xlarge` (1 GPU per node, 10 nodes, the easiest to get),
  `g6e.12xlarge`/`g6e.48xlarge`/
  `g5.48xlarge`/`g6.48xlarge` (G-and-VT quota) — the installer checks the quota and region/AZ offering that actually
  governs the chosen type, not always the P-instance one. Example: `--gpu-instance-type g6e.12xlarge` packs the
  10-server fleet onto 3 nodes (4x L40S each) against the G-and-VT quota instead of 2x p4d.24xlarge against the
  P-instance quota.

  `aws service-quotas request-service-quota-increase --service-code ec2 --quota-code L-417A185B --desired-value 384 --region <region>`
  (approval takes minutes to days for P instances). The quota counts every instance of those families already running in
  the account, so the installer subtracts those and stops in its first phase if the fleet's nodes do not fit; for p4d it
  only warns when the quota covers the 2 nodes but not the pool's maximum. **p4d.24xlarge is offered in some regions and
  AZs only**: the first phase stops if the region has none, and the inference phase stops if none of the GPU nodes' AZs
  offers it (`min` strategy uses one AZ: pick `ha`, or subnets in an AZ that has it). p4d On-Demand capacity is often
  short: reserve it (EC2 Capacity Reservation or Capacity Block) and pass `--gpu-capacity-reservation cr-...` so Karpenter
  launches into it first. An install that already runs its models keeps `per-model` until `--gpu-fleet p4d` is passed.
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

### Details to collect from the customer before the call
| Item | Rule |
|---|---|
| AWS account ID and region | The region must offer the GPU instance type (`p4d.24xlarge`); the installer checks this |
| Cluster name | Lowercase, starts with a letter, up to 24 characters |
| State and IAM prefix (`--tf-prefix`) | IAM role names are account-wide: a second install in the same account and region needs its own prefix |
| Straiker customer name and API key | Straiker onboards the tenant first; the key goes in a hidden prompt |
| Base domain, and whether its Route53 zone is in the same account | Otherwise DNS records are added by hand and a certificate ARN is supplied |
| Gateway exposure (public or private) and allowed CIDRs | The installer warns on public with no CIDRs |
| Admin email and alarm email | First Cognito admin; CloudWatch alarm topic |
| SES: sending domain and who controls its DNS, or their own verified identity ARN and From address | New SES accounts are in sandbox (200 mails/day, verified recipients only): request production access early |
| SSO: provider type, client ID, client secret, allowed email domains | The Cognito redirect URI must be registered with the provider |
| Bedrock: model access granted in the region; global or regional inference profile | The installer prompts for the profile |
| Products (Ascend, Defend) and Defend engine | Defend engine v3 is needed for the console's Controls page |
| Own VPC or ours | Own VPC: private and public subnet IDs; the private subnets need outbound routing |

### Must be true before the run (the failures behind the "one go" goal)
- **GPU quota:** P-instance quota of at least 384 vCPUs (`L-417A185B`, 4 x `p4d.24xlarge`); a new account usually has 0-8.
- **GPU capacity:** EC2 capacity is per instance type and per Availability Zone and cannot be checked ahead. For a customer, reserve
  2-4 `p4d.24xlarge` (EC2 Capacity Reservation or Capacity Block) and pass `--gpu-capacity-reservation`; the installer checks it
  first (active, type, AZ, free count). Choose the zones with `--availability-zones`.
- **Capacity checks without a reservation:** the first phase prints Capacity Blocks you could buy (information only). Right after
  the cluster is built, a capacity probe launches the fleet's GPU instances for about a minute in the node zone(s) and terminates them
  (about $1-2 for 2 `p4d.24xlarge`, cents for g6e; needs `ec2:RunInstances`/`TerminateInstances`). It proves capacity exists *now*,
  not later, and blocks with remedies before the data layer is built when there is none. `--skip-capacity-probe` turns it off.
  Before the cluster is built, a zone probe does the same in a temporary VPC (one subnet per zone that offers the GPU type; also needs
  `ec2:CreateVpc`/`CreateSubnet`/`DeleteSubnet`/`DeleteVpc`), builds the cluster with the first zone that has capacity, and stops
  before building anything when no zone has. It is skipped with `--availability-zones`, `--vpc-id` or a reservation.
- **Egress:** the private subnets reach Straiker's artifact source in us-east-1 (no regional endpoint can), Docker Hub (verify
  probes, the multi-arch override) and the Helm repository.
- **DNS:** a Route53 zone in the account needs no manual step; otherwise the customer must add the validation records.
- **Workstation:** the tools above, kept awake for 2-3 hours (use `tmux`); do not edit the scripts during a run; set
  `STRAIKER_STATE_FILE` when running more than one install from one machine.
- A pause ("blocked") is not a failure: fix the named item and re-run the same command.

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
  [--gpu-fleet per-model] \
  [--customer-key-file ./key.txt]
```
`--gpu-fleet per-model` is for Straiker test installs only; customers keep the p4d default.
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
| GPU nodes never appear (`InsufficientInstanceCapacity`) | EC2 has no capacity of that instance type in the AZ(s) the cluster launches in; capacity is per type per AZ and cannot be checked in advance | the inference phase watches Karpenter and stops within minutes (not the 15-minute Helm wait) with AWS's message and remedies; nothing is torn down, a re-run resumes. Remedies: `--availability-zones`, another `--gpu-instance-type`, or a capacity reservation |
| `--gpu-capacity-reservation` ignored, or nodes still on-demand | reservation expired / wrong type / wrong AZ / shared from another account | pre-flight checks each id (active, instance type, Linux + default tenancy, AZ the nodes launch in, free instances) in the first phase and again before the inference phase, and blocks before any cost |
| Need the nodes in specific AZs | default is the region's first 2 AZs (3 with `--provision-strategy max`) | `--availability-zones a,b[,c]` (first = primary, the only node AZ under `min`); with a reservation and no flag its AZ goes first; fixed once the cluster exists; not with `--vpc-id` |

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

### Tear everything down (clean slate)
`scripts/list-cluster-resources.sh --cluster-name <name> --tf-prefix <prefix> --region <region> --profile <profile> [--zone-id <zone>]`
is a read-only inventory of everything the install left in the account (exit 0 = nothing left). Run it before, to see what will go,
and after, to prove it is clean. Then:

```bash
STRAIKER_STATE_FILE=~/.straiker/install-<name>.json scripts/uninstall-straiker.sh --delete-namespace --destroy-eks --purge-state-bucket --yes
```

It removes, in order: the Helm releases and namespace, the edge and CloudWatch Terraform, the **data layer** (Aurora and its final
snapshot, MSK, OpenSearch, ElastiCache, EFS, Cognito, SES identity and DNS records, DynamoDB, KMS, secrets with no recovery window,
the grid bucket), the **artifacts** (ECR mirror images and repositories, the models bucket), the GPU nodes and load balancers, the
EKS cluster and VPC, the install's ACM certificates and its own Route53 records, and finally (`--purge-state-bucket`) every version in
the Terraform state bucket and the bucket. Left on purpose: account-wide service-linked roles, the Route53 hosted zone, other records
in it, anything not created by this install. It is irreversible; delete `~/.straiker/install-<name>.json` afterwards.

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

## 6b. Console: new Defend overview and Controls (platform API)

The console's Defend overview (identities, surfaces, agents, models, tools/MCP, findings) and Controls call the platform
API through the api-gateway with the console's own signed session. All automatic with `--data-layer` and api-gateway
2.3.13 or newer; with an older gateway the installer keeps both off (sign-in would end in 401). What each piece does:

| Piece | Where | Why |
|---|---|---|
| Gateway accepts the console session | api-gateway `feature/onprem-session-auth` (image `v2.3.13-rc2`, **not on main yet**), env `ONPREM_SESSION_SIGNING_KEY` from the console's `frontend-session-source` secret | the on-prem console signs its own session instead of passing a Cognito token |
| Role -> scopes for that session | gateway `straiker.onprem-session.role-scopes` (= foundation `authz/permissions.yaml`) | platform services authorize on scopes; SaaS puts them in the Cognito token |
| Flags `defend-platform-api-overview`, `control-policies` | phase `straiker-core` | turn the views on |
| Organization record (`tenant_directory`) | phase `straiker-core` (`ensure_platform_tenant`): the console's first `customers` id, named after `--straiker-customer-name` | otherwise "no tenant record was found for your organization" |
| ClickHouse read profile `readonly=2` | `charts/straiker-clickhouse` | grid sets per-query limits; `readonly=1` made inventory return 502 |
| Registry -> Argus control catalog | `straiker.registry.gateway.url` (phase `platform-services`) | default control policies (Endpoint, Gateway, Browser, Cloud) |

**Merge to api-gateway `main`:** only the auth commits (`4a813e0`, `edfd29a`), not `chore/onprem-release`'s build changes.
Then cut a release tag and re-pin `charts/platform-api-gateway` and `charts/straiker-artifact`.

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
- **GPU sizing**: customers run the p4d fleet (all models unquantized on A100 40 GB, thanos at 32k context); Straiker's test
  installs run `--gpu-fleet per-model` (vision/wanda/kev-non-agentic on g5, kev-agentic on g6, thanos on g6e; the SaaS regions
  also use g6e). Switching an install between the two: `--gpu-fleet <shape> --phase straiker-system,straiker-inference --rerun-phase`;
  the model servers move to the new nodes and Karpenter removes the empty old ones after an hour.
- **thanos model profile restored.** It was dropped from `charts/straiker-inference` on 2026-11-13 (commit `1cff360`), so a new or
  re-run `inference-thanos` rendered with no model path. dl-test kept running only because its release predates that change.
- **Dashboards and tracing** (Grafana, OpenTelemetry, Argo CD from the reference architecture) are not part of this install; CloudWatch
  covers metrics, logs and alarms. Re-run `--phase observability --rerun-phase` after changing the edge (the ALB alarms follow the
  ALB) or adding an Aurora cluster.
- **Existing installs** get CloudWatch with `--phase observability`; log groups the agent created earlier and a hand-installed add-on
  are adopted, not recreated. The cluster needs the `eks-pod-identity-agent` add-on (the phase stops with the command if it is missing).
- **WAF tuning**: body rules only count. Review the counted matches in the WAF log after the first real traffic and decide per rule;
  change them in `terraform/aws/edge` (`waf_managed_rule_groups`), then `--phase edge-infra --rerun-phase`.
- **Edge**: `--edge-type internal` is a port-forward with self-signed certificates, for offline tests only.
- Rotate the customer key after any test where it was pasted into a chat or a shell history.
