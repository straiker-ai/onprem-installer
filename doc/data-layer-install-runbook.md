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
| Edge | **One internet-facing Application Load Balancer** (`--edge-type xalb`, the default): ACM certificates, TLS 1.2+, **AWS WAF**. Hosts `straiker.<domain>`, `straiker-ascend.<domain>` and the api-gateway `api.<domain>` | `terraform/aws/edge` (WAF, IAM, certificate) + AWS Load Balancer Controller; Caddy (`--edge-type internal`) is for offline tests only |

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
- Bedrock usable for `anthropic.claude-haiku-4-5-20251001-v1:0` and `anthropic.claude-sonnet-4-6`. The "Model access" page
  is retired: models switch on at first use, and Anthropic may ask first-time accounts for a use-case form (open the model
  once in the Bedrock playground). No IAM policy or SCP may deny `bedrock:InvokeModel`. The installer's preflight makes a
  real call and blocks with a clear message if it fails.
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
- **A domain** (`--domain customer.com`). The console hosts are `straiker.` and `straiker-ascend.<domain>`; the
  api-gateway is `api.<domain>` (change it with `--installer-arg --gateway-domain --installer-arg <name>`). With `--route53` (the domain's
  public zone is in this account) both certificates and every DNS record are automatic; `--domain` must then be the zone's own name. Otherwise
  pass `--certificate-arn` (an ISSUED ACM certificate in the cluster's region covering the three console hosts) and add the DNS records
  yourself (the console names as CNAMEs to the ALB). The api-gateway shares the ALB with the console; its certificate is issued by the
  installer from the domain:
  - **`--create-zone` (with `--route53`)**: phase `dns-zone` (Terraform, `terraform/aws/dns`, state `s6r-onprem/dns.tfstate` in the install bucket) creates the
    public zone for `--domain` and the API gateway's ACM certificate (tagged `straiker:cluster`, so `gateway-cert` reuses it) with its DNS validation record.
    It then prints the four name servers and stops, before any cost, until the delegation is in place. **Manual step, by whoever manages the parent zone**
    (Route53 in another account, Cloudflare, a registrar): add one `NS` record named `<domain>` (TTL 300, DNS only on Cloudflare) with the four name servers.
    Verify with `dig +short NS <domain>`: it must return exactly those four names (any order, trailing dots). Type `yes` at the prompt; the installer re-checks your
    resolver, 8.8.8.8 and 1.1.1.1. With no terminal it stops with the same instructions; re-run the same command after delegating. The zone has
    `prevent_destroy` and the stack is not part of `--destroy-eks`, so teardown keeps it (delete it by hand with `tofu destroy` after removing the lifecycle guard).
    The certificate stays PENDING_VALIDATION until the zone is delegated; the gateway step waits for ISSUED.
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
| Bedrock: models invokable in the region (first-use form done); global or regional inference profile | The installer prompts for the profile |
| Products (Ascend, Defend) and Defend engine | Defend engine v3 is needed for the console's Controls page |
| Own VPC or ours | Own VPC: private and public subnet IDs; the private subnets need outbound routing |

### Must be true before the run (the failures behind the "one go" goal)
- **GPU quota:** P-instance quota of at least 384 vCPUs (`L-417A185B`, 4 x `p4d.24xlarge`); a new account usually has 0-8.
- **GPU capacity:** EC2 capacity is per instance type and per Availability Zone and cannot be checked ahead. For a customer, reserve
  2-4 `p4d.24xlarge` (EC2 Capacity Reservation or Capacity Block) and pass `--gpu-capacity-reservation`; the installer checks it
  first (active, type, AZ, free count). Choose the zones with `--availability-zones`.
- **Capacity checks without a reservation:** the first phase prints Capacity Blocks you could buy (information only). There is no
  probe after the cluster is built. When GPU nodes are not available the install keeps waiting for them, up to 6 hours
  (`GPU_WAIT_HOURS`), and Karpenter tries every instance type listed in `--gpu-instance-type`. It stops early only for errors that
  waiting cannot fix (quota, permissions, bad image or subnet). Sizes of one family can be mixed (e.g. `g6e.4xlarge,g6e.2xlarge,g6e.xlarge`): the
  per-server CPU/memory request is lowered to fit the smallest listed size, so a node of any listed size gets pods as soon as it exists. `--skip-capacity-probe` turns off the zone probe below.
  Before the cluster is built, a zone probe does the same in a temporary VPC (one subnet per zone that offers the GPU type; also needs
  `ec2:CreateVpc`/`CreateSubnet`/`DeleteSubnet`/`DeleteVpc`), builds the cluster with the first zone that has capacity. When no zone has any it warns and
  continues. It is skipped with `--availability-zones`, `--vpc-id` or a reservation.
- **High availability:** the default `--provision-strategy min` is a single-zone proof of concept. With `ha` (2 zones) or `max`
  (3 zones) the installer runs 2 replicas of the platform services (foundation, grid, portico, registry, api-gateway), defend, edge
  and the ascend control plane, spreads them over zones (soft rule, so a zone without capacity cannot leave a pod Pending), and adds
  a PodDisruptionBudget to the platform charts. GPU inference is strict: the two replicas of each model must be in different zones
  (`DoNotSchedule`), so a model replica stays Pending if the second zone has no GPU capacity (the pre-build zone probe only checks one
  zone). The system node group is an Auto Scaling group over all zones, and the verify phase fails if any zone has no node or a
  service's replicas share one zone. Not covered yet: the platform connect and databridge services, ascend workers and ingest stay
  at 1 replica.
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
| Bifrost second replica `CrashLoopBackOff`, `exec format error` | the mirrored `maximhq/bifrost` tag is amd64-only and the nodes are Graviton (a node that cached an older good copy hides it) | `ensure_multiarch_images` copies the multi-arch upstream into your ECR on every artifacts-sync (now also on direct runs); Bifrost's pull policy is `Always`. Root cause was the source tag `onprem-base/maximhq/bifrost:v1.6.7` in Straiker's artifact account being a single image although Docker Hub's is a multi-arch index; it was re-copied with `crane copy docker.io/maximhq/bifrost:v1.6.7 <source>` (the Hauler mirror build keeps indexes for every other image). `verify-data-layer` now fails any mirrored third-party image that lacks an architecture the cluster's nodes run |
| Pods `FailedCreatePodSandBox ... failed to assign an IP address` | one private /24 (251 IPs) full of nodes, each holding spare IPs | the VPC CNI keeps 3 minimum / 1 warm spare IPs per node on a `min` cluster (8 / 2 on ha/max) |
| HPAs show `<unknown>`, `kubectl top` fails, metrics API `FailedDiscoveryCheck` | the metrics-server add-on serves on 10251, which the node security group did not open | the node security group allows the control plane to reach 10251; `verify-data-layer` checks the metrics API |
| Bifrost log: `bedrock-mantle:ListModels ... access_denied` | its Bedrock role could not list the OpenAI-compatible endpoint's models | the role is allowed `bedrock-mantle:ListModels` (list only) |
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

**Argus v3 is the only Argus engine on-prem; Argus v1 (`straiker-defend`) was removed** (section 6i). It runs on the AWS data tier (MSK,
ElastiCache, Secrets Manager), exactly as in Frankfurt (its own ElastiCache `prod-euc1-argus`, MSK `prod-euc1-databridge`, S3 and Secrets Manager
bundle, read through a Pod Identity role). The data tier is always installed on AWS (`--data-layer` is accepted and does nothing); GKE has none, so
the Defend product is refused there. Argus v3 serves only `/api/v3/*` (detect, the Copilot
webhooks, `/api/v3/health`) and the internal controls routes. The gateway sends `/api/v3/detect` and the integration detect paths to
`argus-service` (Argus v3). `/api/v1/detect` is unavailable (the gateway chart still carries that route, as in the SaaS regions that run v3
only; clients must use `/api/v3/detect`).

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

**Ascend on Argus v3 (automatic).** Iris's graders switch from v1 to `/api/v3/detect` only when two things exist (`iris/detector/argus_v3.py`):
the endpoint (set by the installer with `--data-layer`) and an `sk_agt_` key of an agent named `iris-grader`, stored as `ARGUS_V3_API_KEY` in
`straiker-secrets`. SaaS mints that key by hand per region; here phase `straiker-ascend` does it (skip with `--no-iris-grader-mint`):
1. It reads the console's organization id (`customers`, `platform_tenant_id` in the state file) and calls the registry's onboarding API from a
   short-lived pod: `POST /api/v3/onboard/custom-agent` with `{"label":"iris-grader","mode":"api","fields":{"archetype":"chat_assistant"}}` and
   `Idempotency-Key: iris-grader-<cluster>`. The registry only decodes the `X-Straiker-Auth-Context` header (tenant and scopes) and is reachable
   only inside the cluster, the same call the platform repo's smoke test makes.
2. The key comes back once; if the agent already exists the registry converges on it, and the installer reads the active key back through
   `GET /api/v3/integrations/{id}/keys/{keyId}/reveal`. A lost Secret therefore never needs a second agent.
3. It checks Argus v3 accepts the key (`POST /api/v3/detect` through the in-cluster gateway, retried up to 90 s while the new agent reaches the
   engine through MSK). **Only then** it stores the key: a rejected key is never stored, which is the failure Mumbai had until 2026-11-04.
4. On an existing install it rolls the probe and recon workers (one pod at a time) so they read the key; a fresh install starts them with it.
Any failure is a warning, never an aborted install: Ascend's Argus-based grading stays off (`argus.enabled=false`: those results are unknown and excluded from scoring), and re-running
`--phase straiker-ascend` retries. The agent is created in the customer's own organization, so `iris-grader` appears in the console's agent list
(SaaS keeps it in an internal tenant). By hand instead (as in the SaaS regions; also the fallback with `--no-iris-grader-mint` or when the automatic step warns): create the agent in the
console (Custom agent, name `iris-grader`, threat-model class chat assistant) and copy its key (shown once), then re-run
`--phase straiker-ascend --rerun-phase` with `ARGUS_V3_GRADER_KEY=sk_agt_...` in the environment (read it with `read -rs`, never paste it into a
chat or shell history). The installer stores it only after Argus v3 accepts it (same check as the automatic path: `POST /api/v3/detect` through
the gateway, retried for up to 90 s) and rolls the probe and recon workers; a key that is rejected or is not an `sk_agt_` key is not stored. Check: `kubectl logs deploy/straiker-ascend-probe-worker` shows `argus_v3` requests and no 401s.
Not verified on a running install yet (see the fresh-install checklist).

## 6i. Argus v1 is removed

Argus v3 is the only Argus engine on-prem. What changed (SaaS regions without v1, Frankfurt and Mumbai, are set up the same way):
- no `straiker-defend` release (v1 engine and settings-sync), no `straiker-defend` chart or phase, and no `--defend-engine v1` (the flag is
  accepted as `v3` and ignored; `v1` is refused). The v1 image is no longer mirrored;
- the console's `ARGUS_ENDPOINT` stays unset (the chart then leaves the variable out), as in Frankfurt and Mumbai, whose infra notes say an unset
  endpoint "turns one feature off, nothing else". Off: **Saige** (the detect playground, which called `/api/v1/detect` and only works on sample
  applications) shows "taking a break"; the Argus entry of `/health/detailed` reports unhealthy (the pod probes use `/api/health` and nothing in
  this repo calls `/health/detailed`); attachment downloads in turn views (`/api/v1/attachments`) fail. Accepted: they were v1 features;
- the `defend.<domain>` edge route and its hostname are gone, and `/api/v1/detect` and `/api/v1/integrations/*/detect` are unavailable: callers
  use `/api/v3/detect`. The unused `argus/session` secret (the old v1 session key) is no longer created;
- Ascend's graders use Argus v3 only, with the automatically created `iris-grader` key (section 6). Without a key (or without `--data-layer`)
  its Argus-based grading is off.

**Installs that still have v1** (made before this change): phase `straiker-ascend` removes the old release and what only it used (PDB,
session-key ExternalSecret and Secret) after it has moved the graders to v3; without Ascend, phase `straiker-argus-v3` does it. Re-run
`--phase straiker-argus-v3,straiker-core,straiker-edge,straiker-ascend`: the frontend rolls (2 replicas, one at a time), the edge route disappears,
and Ascend's workers roll onto v3. Kept on purpose: the empty ECR chart repository `<prefix>/charts/straiker-defend` (Terraform cannot delete a
non-empty repository on an existing install), the `defend` name in older ACM certificates, and the `straiker-defend` entries of the uninstaller (so
an old install can still be removed). A later `aws-data` run on an old install deletes the unused `argus/session` secret (7-day recovery window).
The non-AWS (GKE) path has no Argus v3, so the Defend product is refused there (Ascend alone still installs, with its Argus-based grading off).


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

## 6c. Sizing against the reference architecture

- **Metrics API:** the `metrics-server` EKS add-on is installed by phase `eks-cluster`, and `verify-data-layer` checks it
  (`kubectl top nodes`). Every HPA needs it: without it replica counts never change.
- **Production replicas and HPAs:** on with `--provision-strategy ha|max`, or with `--production-sizing` on any cluster. Console
  and platform services (foundation, registry, grid, portico, databridge) start at 2 and autoscale; connect/notify 3 per role;
  Bifrost 2; Argus compactor 2; Ascend control plane 2, probe workers 4, recon and report workers 2, each with an HPA.
  Re-run the service phases to apply it to an existing install.
- **Done since:** Ascend adjustment worker (6g), Helm charts in ECR and OpenTelemetry (6e), the second Aurora cluster for Ascend/Bifrost (6f),
  the extra KMS keys and the transcripts/exports/logs buckets (6e), CloudTrail and VPC Flow Logs (6d).
- **Skipped on purpose:** Grafana, EKS 1.36, Graviton system nodes (m7g.xlarge x2), ClickHouse on r7g.4xlarge and the pool names
  general/defend/ascend (they are shared/argus/iris here). Argo CD is not applicable to customer installs (no Straiker git source of truth).
- **GPU mix is intentionally different:** the reference shows vision at 4 replicas; here every local model (thanos, vision, wanda, Kev
  agentic and non-agentic) runs 2 replicas, the list and count fixed by the manager on 2026-11-13. Changing it is a product decision.

## 6d. Audit trail (opt-in): VPC Flow Logs and CloudTrail

Both are off unless asked for; they are applied by phase `observability` and remembered.

| Flag | What it creates | Cost / notes |
|---|---|---|
| `--vpc-flow-logs` (`--flow-logs-traffic ALL\|ACCEPT\|REJECT`) | VPC Flow Logs of the cluster VPC into CloudWatch Logs group `/aws/vpc/<cluster>/flow-logs` (90-day retention) with its own IAM role | Billed per GB ingested. `REJECT` records only refused connections and is far cheaper |
| `--cloudtrail` (`--cloudtrail-multi-region`) | Trail `<cluster>-trail` (management events, log-file validation, global service events) into a private, TLS-only, SSE-encrypted, versioned S3 bucket `<cluster>-<account>-cloudtrail` (365-day expiry) | A second trail in an account that already has one, or an organization trail, is billed: check first. Audit logs outlive an `--destroy-eks` teardown unless the bucket is emptied |

Apply: `scripts/install-straiker.sh ... --vpc-flow-logs --cloudtrail --phase observability --rerun-phase --yes`.

## 6e. Encryption keys, buckets, charts in ECR, OpenTelemetry

**KMS layout (`--kms-layout single|split`).** Decided once per install and remembered (`kms_layout` in the state file); a later flag is ignored with a warning.
- `split` (default on a **fresh** install): EFS (model cache) uses the `models` key, Secrets Manager the `secrets` key, new EBS volumes (the `gp3` StorageClass) the `ebs` key; Aurora, ElastiCache, MSK, DynamoDB and OpenSearch keep the `data` key. The `transcripts` and `logs` keys exist too.
- `single` (an install that already has a cluster or a `data` key): nothing is re-keyed. Changing it would replace the EFS file system (the ~65 GB model cache is re-downloaded) and re-key every secret, so it is never done automatically. Node root volumes use the default EBS key in both layouts.
- Existing installs get only the additive part on the next `aws-data` run: the `transcripts` and `logs` keys, the three buckets below, and a wider `kms:Decrypt` grant on the pod roles. No existing resource changes.

**Node root volumes on the customer-managed key (`--encrypt-node-volumes`, opt-in, remembered, fresh installs only).** The system node group's
root volume and every Karpenter node's (`eks.ebsKmsKeyId` in the `straiker-system` chart) are encrypted with the `<cluster>-ebs` key instead of the
AWS-managed default. The key policy lets the Auto Scaling service-linked role use it, the Karpenter controller role gets `kms:CreateGrant`/`Decrypt`/
`GenerateDataKey*`, and the installer creates `AWSServiceRoleForAutoScaling` when the account has none (outside Terraform: it is account-wide). The
system node group's root volume becomes 50 GiB (`system_node_volume_size_gb`). On a cluster that already exists the flag is ignored: it changes the
launch template and every node class, which replaces every node (GPU nodes included); `ENCRYPT_NODE_VOLUMES_FORCE=true` overrides it for a planned
maintenance window. Not verified on a running cluster yet: see the fresh-install checklist below.

**Buckets.** `<cluster>-<account>-transcripts` (key `transcripts`, versioned), `-exports` (data key), `-logs` (key `logs`) next to `-grid-artifacts`. Private, TLS-only. No service writes to them yet: they exist for the reference layout and for the services that adopt them.

**Charts in ECR (`--charts-from-ecr`, opt-in, remembered).** The `aws-artifacts` phase creates one ECR repo per chart (`<prefix>/charts/<name>`). With the flag, every run packages `charts/*`, pushes them (OCI, mutable tag = the chart version), pulls them back and deploys from the pulled copy, so what runs is what ECR holds. A chart that cannot be pushed or pulled is used from `charts/` with a warning. Existing installs: run `--phase aws-artifacts --rerun-phase` once first (creates the repos).

**OpenTelemetry (`--otel`, opt-in, remembered).** The `observability` phase creates the collector's IAM role (Pod Identity), mirrors nothing itself, and installs the `straiker-otel` chart (AWS Distro collector, 2 replicas, namespace `observability`): traces go to X-Ray, metrics to CloudWatch (namespace `Straiker/<cluster>`). It also writes `otel-secret` (standard `OTEL_*` variables pointing at `otel-collector.observability:4318`) in the app namespace. Order for a first enable: `--phase aws-artifacts,artifacts-sync --rerun-phase` (mirrors the collector image), then `--phase observability --otel`, then `--phase platform-services,straiker-argus-v3 --rerun-phase` so the pods read the secret. Not verified: that every service's SDK honours these standard variables (the secret's original contract is not in this repo).

## 6f. Second Aurora cluster (Ascend, Bifrost)

**Layout (`--aurora-layout single|split`).** Decided once per install and remembered (`aurora_layout`); a later flag is ignored with a warning.
- `split` (default on a **fresh** install): a second Serverless v2 cluster `<cluster>-aurora-ascend` (1-8 ACU) holds the `iris` (Ascend) and `bifrost` databases; `<cluster>-aurora` keeps the platform services and the frontend. Ascend's host comes from the `ascend` endpoint recorded by `aws-data`; the per-cluster bootstrap Job, admin Secret and DSNs already existed in `straiker-data`.
- `single` (an install that already has `<cluster>-aurora`): nothing moves. An existing `-ascend` cluster is always treated as `split` (leaving it out would make Terraform destroy it).
- Forcing `split` on an existing install creates an **empty** `iris` database on the new cluster. Ascend's data stays on the old cluster and Ascend starts blank. To keep it: dump the old `iris` database (`pg_dump` from a pod, Aurora master secret in Secrets Manager), run `aws-data` and `data-bootstrap` with the flag, restore into the new one, then re-run `straiker-ascend`.

**Bifrost (`--bifrost-postgres`, opt-in, remembered).** Until now Bifrost kept its configuration and request logs in a per-pod SQLite file, so its 2 replicas did not share state. With the flag the `straiker-bifrost` chart writes `config_store` and `logs_store` (Postgres) into `config.json`, host from Aurora (the `ascend` cluster in `split`), password from `straiker-db-dsn` (`PASSWORD_bifrost`). Not verified: the exact `config_store` schema of the pinned Bifrost image (v1.6.7); check the pods start and `/health` answers after enabling.

## 6g. Ascend adjustment worker

`straiker-ascend` (0.1.15) now runs `straiker-ascend-adjustment-worker`, as the SaaS regions do (`iris-adjustment-worker`). When a finding is disputed or undisputed, the control plane queues an event on the `fp_adjustments` Redis stream; the worker re-counts the assessment's stored report from it. Without it disputes were queued and never applied. It uses the same `straiker/iris` image, the iris Valkey and the control-plane endpoint as `report-worker`.

**Image.** The first on-prem iris image (`onprem-v2026.11.6.1`) did not contain `run_adjustment_worker.py` (the on-prem build file `onprem/Dockerfile` in the iris repo did not copy it; SaaS builds from a different Dockerfile that does). Fixed in iris PR #653; image `onprem-v2026.11.18` (built by hand: the `onprem-iris-build` project reads `buildspec.yml` at the repo root while iris keeps `onprem/buildspec.yml`, so tag-push builds fail; start it with `--source-version <tag> --buildspec-override onprem/buildspec.yml`, then `crane tag` the version name onto the commit-SHA image). The chart value `adjustmentWorker.enabled` stays **false** until you have mirrored that image and checked it holds the file (`kubectl run ... --image=<ecr>/straiker/iris:onprem-v2026.11.18 -- ls /app`); then enable it with `--ascend-adjustment-worker` (remembered; the chart value stays false by default).

It is **always one replica** (the iris code does a read-modify-write per assessment and says so): no HPA, `--production-sizing` does not change it, and the Deployment is `Recreate`, so an upgrade has a short gap in which disputes wait in the stream and are processed afterwards. Once enabled, check it: `kubectl -n straiker get deploy straiker-ascend-adjustment-worker`, then dispute a finding in an Ascend report and see the counts change. Not verified yet.

## 6h. Fresh-install checklist (what only a new cluster can prove)

Run a fresh install with `--kms-layout split --aurora-layout split --encrypt-node-volumes --bifrost-postgres --charts-from-ecr --otel --ascend-adjustment-worker
--production-sizing` (the layout flags are decided once; the others are remembered). Then check:

| Area | Check | Expect |
|---|---|---|
| KMS | `aws kms list-aliases` (cluster name in the alias) | `data`, `ebs`, `models`, `secrets`, `transcripts`, `logs` |
| EFS / secrets | `aws efs describe-file-systems`, `aws secretsmanager describe-secret` | EFS on the `models` key, secrets on the `secrets` key |
| Buckets | `aws s3 ls` | `-grid-artifacts`, `-transcripts`, `-exports`, `-logs` |
| Aurora | `aws rds describe-db-clusters` | `<cluster>-aurora` and `<cluster>-aurora-ascend`; Ascend and Bifrost on the second |
| PVs | `kubectl get storageclass gp3 -o jsonpath='{.parameters}'` | `encrypted` and a `kmsKeyId` |
| Node volumes | `aws ec2 describe-volumes --filters Name=attachment.instance-id,Values=<node>` for a system and a Karpenter node | `Encrypted: true`, `KmsKeyId` = the `ebs` key |
| Charts | installer log | "Charts deployed from ECR (...): N pushed, N pulled" with no fallback warning |
| Bifrost | `kubectl logs deploy/straiker-bifrost` | started with Postgres stores; `pg_tables` count > 0 in the `bifrost` database |
| OTel | `kubectl -n observability get pods`; a smoke trace in X-Ray | 2 collectors Running |
| Ascend | `kubectl get deploy | grep ascend` | adjustment worker 1/1 (iris image `onprem-v2026.11.18` or newer) |
| iris-grader | installer log of `straiker-ascend`; `kubectl logs deploy/straiker-ascend-probe-worker` | "Stored the iris-grader key"; `argus_v3` requests, no 401 |
| No v1 | `kubectl get deploy | grep defend`; the console | no `straiker-defend`; frontend env has no `ARGUS_ENDPOINT`; Saige "taking a break"; no `defend` host routed |
| No legacy in-cluster stores | `scripts/audit-legacy-incluster.sh --kubeconfig <file> --expect-clean` (read-only) | `PASS`: no Valkey, no Postgres, no bundled OpenSearch (only `straiker-benthos` remains), and Benthos writes to the managed OpenSearch domain |
| Verify | `--phase verify-data-layer` | all PASS (Vector `WARN` is expected) |

## 6j. Old in-cluster Postgres, Valkey and OpenSearch

The data tier replaces them (Aurora, ElastiCache, the managed OpenSearch domain), and current `straiker-system` does not create Postgres or Valkey for it
(`postgres=null`, `valkey=null`); the bundled OpenSearch only appears as a fallback when no managed domain was created. Installs made with an older
revision still have all three. `scripts/audit-legacy-incluster.sh` (read-only) prints, for each, whether it exists and whether anything uses it
(references from other workloads, keys, rows, application indices) and where Benthos writes its archives. On dl-test (2026-11-18) all three were unused:
Valkey 0 keys, Postgres 3 empty databases with no write ever, OpenSearch only its own housekeeping indices; Benthos still pointed at the in-cluster
OpenSearch while the console reads the managed domain, so `--phase straiker-system --rerun-phase` is needed there (it also removes the three).
The installer and chart code that serves only the old mode (the Postgres storage class and in-cluster defaults, `postgres.yaml`, `valkey.yaml`, the
repo-root `onprem-architecture.md`) is left in place until a fresh install passes `--expect-clean`; then remove it in one separate change.

## 7. Known gaps and manual steps

- **Straiker-side prerequisites** in section 2 are manual (customer key, image tags, mirror run).
- **Bedrock**: the Model access page is retired; a first-time Anthropic use-case form (console) may still be needed.
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
