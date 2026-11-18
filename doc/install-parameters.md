# Install parameters

Two scripts take parameters. Customers normally use only the first.

- **`scripts/install-data-layer.sh`**: the one-command wrapper. Its flags are listed in section 1, and anything else is passed through with `--installer-arg`.
- **`scripts/install-straiker.sh`**: the phased installer the wrapper runs. Section 2 lists every flag it accepts.

Words used below: **first run only** = fixed once set, ignored on later runs (to change it, start a new install). **Remembered** = stored
in the state file (`~/.straiker/install-<name>.json` when `STRAIKER_STATE_FILE` is set), so a re-run keeps it.

Environment variables: `STRAIKER_STATE_FILE` (state file per install), `AWS_PROFILE`, `AWS_REGION`, `SSO_CLIENT_SECRET` (identity-provider secret, never a flag),
`ARGUS_V3_GRADER_KEY` (Ascend on Defend v3).

---

## 1. `install-data-layer.sh` (the wrapper)

### Required

| Flag | What it does |
|---|---|
| `--cluster-name NAME` | EKS cluster name (lowercase, starts with a letter, up to 24 characters) |
| `--region REGION` | AWS region. Everything is created in this one region |
| `--customer-name NAME` | Straiker customer name (the `<name>` of `<name>@straiker.ai`) |

### Common options

| Flag | What it does | Default |
|---|---|---|
| `--profile PROFILE` | AWS CLI profile to use | `$AWS_PROFILE` |
| `--expect-account ID` | Stop unless the AWS account is this one (guards against the wrong profile) | none |
| `--customer-key-file FILE` | File holding the Straiker customer key (first run only); otherwise a hidden prompt asks once | prompt |
| `--tf-prefix P` | Prefix of the state bucket and of account-wide IAM role names. A second install in the same account needs its own | `s6r-onprem` |
| `--namespace NS` | Kubernetes namespace | `straiker` |
| `--domain D` | Base domain: `straiker.D`, `straiker-defend.D`, `straiker-ascend.D`, `api.D` | none |
| `--route53` | The public Route 53 zone for `--domain` is in this account: certificates and DNS records are automatic | off |
| `--create-zone` | With `--route53`: create the public Route 53 zone for `--domain` in this account if it does not exist, print its four name servers, then wait before building anything until you confirm the NS record was added in the parent zone and `dig +short NS <domain>` returns them. Re-runs skip the wait once it resolves. The zone is never deleted by teardown | off |
| `--certificate-arn ARN` | Without `--route53`: your ACM certificate (same region) covering the console hosts; the `api.D` certificate is still requested (DNS records are printed) | none |
| `--edge-type T` | `xalb` (internet-facing ALB + ACM + WAF), `alb` (internal), `internal` (Caddy, offline tests), `none`, `tailscale` | `xalb` |
| `--products LIST` | Products to install: `ascend`, `defend` | `ascend,defend` |
| `--defend-engine E` | `v3` (Argus v3: needed by the console Controls page and the Detect API) or `v1` | `v3` |
| `--ai-provider-mode M` | `bedrock`, `own-keys`, `trial-key` | `bedrock` |
| `--provision-strategy S` | `min` (one zone, PoC), `ha` (two zones), `max` (three zones, more headroom). First run only | `min` |
| `--availability-zones A,B[,C]` | Zones the cluster uses, in order (first = primary, the only node zone under `min`). Fixed once the cluster exists | region's first 2 |
| `--alarm-email ADDR` | Subscribe an address to the CloudWatch alarm topic (repeatable; each must confirm AWS's mail) | none |
| `--installer-arg ARG` | Pass one extra argument to `install-straiker.sh` (repeatable, e.g. `--installer-arg --admin-email --installer-arg me@x.com`) | none |
| `--yes` | Do not ask for confirmation before creating resources | ask |
| `--check` | Run the pre-flight checks only | off |
| `--status` | Print the phase status and exit | off |
| `-h`, `--help` | Show help | |

### GPU options

| Flag | What it does | Default |
|---|---|---|
| `--gpu-fleet F` | `p4d` (customers: model servers packed on `p4d.24xlarge`, 2 nodes, pool up to 4) or `per-model` (one g5/g6/g6e node per server; Straiker test installs) | `p4d` for a new install |
| `--gpu-instance-type T[,T]` | Pack the p4d fleet onto another EC2 type instead (several same-GPU types allowed, largest first, e.g. `g6e.4xlarge,g6e.2xlarge`) | `p4d.24xlarge` |
| `--gpu-capacity-reservation IDS` | EC2 Capacity Reservation or Capacity Block id(s) (`cr-...`) that GPU nodes launch into first | none |
| `--skip-capacity-probe` | Skip the brief real launch of GPU instances that proves capacity | probe runs |

### Email (SES) and sign-in (SSO)

| Flag | What it does |
|---|---|
| `--ses-domain D` | Send Cognito mail from SES on domain D (DNS records created in Route 53 when the zone is in this account) |
| `--ses-route53-zone-id ID` | Hosted zone to use for the SES records |
| `--ses-identity-arn ARN` + `--ses-from ADDR` | Use your own already-verified SES identity instead (excludes `--ses-domain`) |
| `--ses-configuration-set NAME` | Optional SES configuration set for Cognito mail |
| `--sso-type T` | Identity provider: `google`, `facebook`, `amazon`, `apple`, `saml`, `oidc` |
| `--sso-domains a.com,b.com` | Email domains allowed to sign in |
| `--sso-client-id ID` | Provider client ID (secret via env `SSO_CLIENT_SECRET` or a hidden prompt) |
| other `--sso-*` flags | Per type: see section 2 |

### Waiting behaviour

| Flag | What it does | Default |
|---|---|---|
| `--timeout-minutes N` | Give up waiting after N minutes in total | 240 |
| `--poll-seconds N` | Seconds between checks while waiting | 30 |
| `--multiarch-override R=U` | An image whose copy in your registry lacks arm64: `<repo>:<tag>=<upstream>` (repeatable; `none` disables) | bifrost from Docker Hub |

---

## 2. `install-straiker.sh` (the installer)

### Run control

| Flag | What it does |
|---|---|
| `--plan` | Show the phases and exit |
| `--status` | Per-phase summary (done, next, blocked) and exit |
| `--phase a,b` | Run only these phases, in the listed order |
| `--from-phase name` | Run from this phase to the end |
| `--rerun-phase` | Re-run selected phases even when marked done |
| `--yes` | Skip the interactive resource-creation acknowledgement |
| `--timeout <duration>` | Helm wait timeout (default 20m) |
| `--install-tofu` | Download OpenTofu to `~/.local/bin` if missing |
| `-h`, `--help` | Show help |

### Where it installs

| Flag | What it does |
|---|---|
| `--cloud-provider aws\|gke` | Target cloud (first run only, default `aws`) |
| `--aws-region R` / `--aws-profile P` | AWS region and CLI profile for every command (fall back to `AWS_REGION` / `AWS_PROFILE`) |
| `--gcp-region R` / `--gcp-project ID` | GKE only |
| `--cluster-name NAME` | EKS cluster name (default `s6r-onprem` with `--install-eks`; else taken from the current kubectl context) |
| `--namespace NAME` | Namespace for every Straiker chart (default `straiker`) |
| `--tf-prefix P` | State bucket and account-wide IAM role prefix (default `s6r-onprem`) |
| `--install-eks` | Also create the EKS cluster with Terraform |
| `--data-layer` | Also create the AWS data tier: Aurora, ElastiCache, MSK, EFS, KMS, Secrets Manager (phase `aws-data`) |
| `--provision-strategy min\|ha\|max` | Footprint: zones, NAT gateways, system nodes (first run only) |
| `--availability-zones a,b[,c]` | Zones in order; not with `--vpc-id`; fixed once the cluster exists |

### Network and cluster API

| Flag | What it does |
|---|---|
| `--vpc-id ID` + `--private-subnet-ids IDS` + `--public-subnet-ids IDS` | Use your own VPC (all three together; at least 2 private subnets in 2 zones; the private subnets must already have outbound internet; first run only) |
| `--single-nat-gateway` | One NAT gateway even under `ha`/`max` (one stable egress IP; that NAT becomes a single point of failure) |
| `--private-api-endpoint` | Hide the Kubernetes API from the internet (needs a route into the VPC and `--api-allowed-cidrs`; first run only) |
| `--api-allowed-cidrs CIDRS` | Ranges allowed to reach the private API on 443 |
| `--api-public-cidrs CIDRS` | Ranges allowed to reach the public API (default anywhere) |

### Straiker account and products

| Flag | What it does |
|---|---|
| `--straiker-customer-name NAME` / `--straiker-customer-key KEY` | Your Straiker customer name and API key (prompted if missing; prefer `--customer-key-file` on the wrapper) |
| `--products LIST` | `ascend`, `defend` |
| `--defend-engine v1\|v3` | Detection engine (`v3` default with `--data-layer`) |
| `--ai-provider-mode M` | `own-keys`, `bedrock`, `trial-key` (only when Ascend is selected; safe to change later) |
| `--repo-name N` / `--repo-url U` / `--chart-version V` / `--values FILE` | Helm repository, chart version and extra values for `straiker-system` (`--values` repeatable) |
| `--saas-frontend` | Also create the SaaS-style frontend backends (DynamoDB tables, Kinesis audit stream) |

### Console login and sign-in

| Flag | What it does |
|---|---|
| `--admin-email ADDR` | First administrator (Cognito user; password kept in Secrets Manager). Required by phase `straiker-core` |
| `--reset-admin-password` / `--rotate-admin-password` | Set the admin password again from Secrets Manager / generate a new one |
| `--sso-type T` | `google`, `facebook`, `amazon`, `apple`, `saml`, `oidc` (one per install) |
| `--sso-name N` | `saml`/`oidc` only: the provider's name in Cognito (3-32 letters, digits, hyphens) |
| `--sso-domains LIST` | Email domains allowed through SSO (new users are viewers) |
| `--sso-client-id ID` | Client ID (`google`/`facebook`/`amazon`/`oidc`, or the Services ID for `apple`) |
| `--sso-oidc-issuer URL` | `oidc`: the issuer URL |
| `--sso-saml-metadata-url URL` / `--sso-saml-metadata-file FILE` | `saml`: provider metadata |
| `--sso-apple-team-id ID` / `--sso-apple-key-id ID` / `--sso-apple-private-key-file FILE` | `apple` only |
| `--sso-email-claim CLAIM` | Claim carrying the email when not the standard one (e.g. `preferred_username`) |
| `--allow-sso-change` | Replace a different SSO provider already set up (old users are orphaned) |
| `--skip-sso-preflight` | Skip the SAML/OIDC reachability and certificate checks |
| `--ses-domain D` / `--ses-route53-zone-id ID` / `--ses-identity-arn ARN` / `--ses-from ADDR` / `--ses-configuration-set N` | Email sending, as in section 1 |

### GPUs and models

| Flag | What it does |
|---|---|
| `--inference-mode vllm\|bedrock` | Run the model fleet on GPU nodes (`vllm`, default) or none (`bedrock`: vision, wanda, Kev and thanos unavailable) |
| `--inference-profile production\|test` | `production`: one server per GPU, never shared or quantized. `test`: may share GPUs and quantize thanos. **Never use `test` for a customer** |
| `--gpu-fleet p4d\|per-model` | Fleet shape (see section 1) |
| `--gpu-instance-type T[,T]` | EC2 type(s) for the packed fleet |
| `--gpu-max-nodes N` | Most GPU nodes the pool may grow to (default 4) |
| `--gpu-capacity-reservation IDS` | Reservation id(s) the GPU nodes use first |
| `--inference-models a,b,c` | **Testing only.** Deploy just these models; use only with `--phase straiker-inference` |
| `--skip-capacity-probe` | Skip the GPU capacity probe |

### Edge: load balancer, domain, certificates

| Flag | What it does |
|---|---|
| `--edge-type T` | `xalb` (default on EKS), `alb`, `internal`, `none` (default on GKE), `tailscale` |
| `--custom-domain D` | Base domain for the edge (required for `alb`/`tailscale`; for `none`, sets sign-in redirect overrides) |
| `--xalb-route53` | `xalb`: the Route 53 zone is in this account; certificate and DNS (ExternalDNS) automatic |
| `--alb-route53` | `alb`: same for the internal ALB (no ExternalDNS) |
| `--alb-certificate-arn ARN` | Your ACM certificate for the load balancer (needed unless the matching `*-route53` flag is used) |
| `--alb-subnets IDS` | `alb`: subnets for the ALB (default: auto-discovered) |
| `--alb-provision-bastion` | `alb`: a small EC2 bastion (no public IP) to test reachability over SSM |
| `--internal-lb-source-ranges CIDR` | Source ranges allowed to reach the console hosts (`alb` defaults to the VPC range) |
| `--waf-rate-limit N` | Requests per 5 minutes per IP before WAF blocks (default 10000, 0 = no rate rule) |
| `--tailscale-oauth-client-id ID` / `--tailscale-oauth-client-secret S` | `tailscale` edge: your OAuth client |
| `--tailscale-cluster-issuer-email ADDR` | `tailscale` edge: Let's Encrypt contact email |
| `--update-alb-certificate` with `--alb-cert-file`, `--alb-key-file`, `--alb-chain-file` | One-off: re-import a certificate into the ACM ARN already in use |

### API gateway (the API behind SDK and console calls)

| Flag | What it does |
|---|---|
| `--gateway-exposure public\|internal\|none` | Who can reach it: internet-facing (default, TLS required), VPC only, or in-cluster only |
| `--gateway-domain FQDN` | Its hostname (default `api.<domain>`); the installer requests the certificate and adds the DNS records when the zone is in this account |
| `--gateway-zone-id ID` | Route 53 zone for the gateway domain (default: found by name) |
| `--gateway-cert-arn ARN` | Your own ACM certificate for the gateway |
| `--gateway-allowed-cidrs LIST` | Source ranges allowed to reach a public gateway (default any) |

---

## 3. Teardown and inventory

| Script and flag | What it does |
|---|---|
| `scripts/uninstall-straiker.sh` | Remove the install. Reads the state file (`STRAIKER_STATE_FILE`) |
| `--aws-profile P` | AWS profile (otherwise taken from the state file) |
| `--delete-namespace` | Also delete the namespace |
| `--destroy-eks` | Also destroy the cluster, data layer, artifacts, edge and CloudWatch resources |
| `--purge-state-bucket` | Also delete every version in the Terraform state bucket and the bucket |
| `--yes` | Do not ask for confirmation |
| `scripts/list-cluster-resources.sh --cluster-name N --tf-prefix P --region R --profile PR [--zone-id Z]` | Read-only inventory of what an install left; run before and after teardown (exit 0 = clean) |
