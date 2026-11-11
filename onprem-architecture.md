# Straiker on-prem installer: what it does, what it creates, how it differs from SaaS

Sources: `README.md`, `scripts/install-straiker.sh` (phases), `terraform/aws/{tfbe,eks,artifacts,edge}`,
`charts/*`, `doc/egress-allowlist.md`. SaaS side: `prod-euc1-handoff.md` (Frankfurt) and `infra/live/prod-euc1`.

## 1. How it runs

`curl .../dist/install.sh | bash -s -- --install-eks --aws-region <r>` downloads a versioned bundle
(installer script + `terraform/` + `charts/`) to `~/.straiker/installer/<version>/`, then runs
`install-straiker.sh`. State lives in `~/.straiker/install.json`; each phase is marked
done/blocked, so re-running resumes. Terraform (OpenTofu 1.11) runs from `/tmp/straiker-tf`.
The installer runs on an operator machine (laptop, jump host, CloudShell), not inside the cluster.

## 2. Phases (in order)

| # | Phase | What happens | Where it lands |
|---|---|---|---|
| 1 | `eks-tfbe` | S3 bucket for Terraform state (versioned, SSE, public access blocked) | AWS |
| 2 | `eks-cluster` | (`--install-eks`) VPC + NAT + EKS + addons + system node group + Karpenter IAM/SQS | AWS |
| 3 | `karpenter` | (`--install-eks`) Helm-install Karpenter controller v1.14.0 | K8s |
| 4 | `k8s-preflight` | Checks kubectl, a usable StorageClass, and (BYO cluster) Karpenter CRDs/controller | none |
| 5 | `aws-artifacts` | 16 ECR repos, models S3 bucket, hauler IAM role + Pod Identity, models-reader role, optional Bedrock role | AWS |
| 6 | `artifacts-sync` | Helm `straiker-artifact`: credential Secret + two Jobs. Image-mirror copies Straiker images from Straiker's us-east-1 ECR into the customer's ECR. Model-sync (rclone) copies model weights from Straiker's S3 into the customer's bucket. Credentials come from a broker Lambda URL, using `--straiker-customer-name/key`. Can take hours; installer blocks until done | K8s Jobs, writes AWS |
| 7 | `straiker-system` | Helm: Karpenter NodePools + EC2NodeClasses (shared, argus, iris, gpu), NVIDIA device plugin + RuntimeClass, OpenSearch (single node, 10Gi), Postgres StatefulSet (20Gi; DBs `platform`, `iris`), Valkey, Benthos (Redpanda Connect, `/archive` to OpenSearch) | K8s |
| 8 | `shared-secrets` | Generates `straiker-secrets` (internal API keys, vLLM key, bootstrap admin password) | K8s |
| 9 | `ai-provider-secrets` | (Ascend only) own-keys / bedrock / trial-key credentials into that Secret | K8s |
| 10 | `straiker-core` | Frontend (console + migrate/bootstrap jobs), Dex (OIDC), Bifrost (LLM gateway) | K8s |
| 11 | `straiker-inference` | One vLLM release per GPU model: antman, hulk, quicksilver, thor, vision, wanda (Defend) and thanos (Ascend) | K8s, GPU nodes |
| 12 | `straiker-defend` | Argus (detection API) + settings-sync, HPA/PDB. Always installed, Ascend calls it too | K8s |
| 13 | `straiker-ascend` | Iris: control-plane, probe-worker, probe-shadow, recon-worker, report-worker, db-migrate, cleanup CronJob | K8s |
| 14-19 | edge (`--edge-type`) | `none` (default, bring your own ingress), `internal` (Caddy, self-signed), `tailscale` (Caddy + cert-manager + Route53 DNS-01 + Tailscale operator), `alb` (internal ALB), `xalb` (internet-facing ALB). Uses `terraform/aws/edge` for IAM, ACM cert, optional bastion | AWS + K8s |

Product selection (`--products ascend,defend`) decides which NodePools and models are enabled.
`--provision-strategy min|ha|max` controls AZ count, NAT count and system node count
(min = 1 AZ, 1 node, PoC only; ha = 2 nodes; max = 3 nodes).

## 3. Resources: created on AWS vs only inside the cluster

### 3a. Created in the customer's AWS account (via Terraform)

| Resource | Module | Notes |
|---|---|---|
| S3 tfstate bucket | `tfbe` | `<prefix>-tfstate-<region>-<acct>`, versioned |
| VPC, public + private subnets, IGW, route tables | `eks` (skipped with `--vpc-id`) | 10.0.0.0/16 default; subnets tagged for ELB + Karpenter discovery |
| NAT gateway(s) + Elastic IP(s) | `eks` | 1 for `min`, 1 per AZ for `ha/max`, or 1 via `--single-nat-gateway`. Not created in BYO-VPC |
| EKS cluster v1.35, security groups, OIDC provider | `eks` | Public API by default; `--private-api-endpoint` available |
| EKS addons | `eks` | vpc-cni, coredns, kube-proxy, aws-ebs-csi-driver, eks-pod-identity-agent |
| IRSA roles | `eks` | vpc-cni, ebs-csi |
| System managed node group | `eks` | m5.large / m5a.large, tainted `CriticalAddonsOnly` |
| Karpenter node IAM role, controller role, SQS interruption queue, EventBridge rules, Pod Identity association | `eks` | Node role has SSM, CNI, ECR-read |
| Karpenter-launched EC2 nodes | runtime | shared/argus/iris arm64 (m/c 6g/7g); GPU g4dn/g5/g6e (limit 20 GPUs); EBS gp3 50-200Gi |
| EBS volumes (PVCs) | runtime | OpenSearch 10Gi, Postgres 20Gi |
| ECR repositories (16) | `artifacts` | `<prefix>/<image>`, scan on push |
| Models S3 bucket | `artifacts` | versioned, SSE, private |
| IAM roles + Pod Identity: hauler (ECR push + bucket write), models-reader, optional bifrost-bedrock | `artifacts` | Pod Identity, no static keys |
| ALB controller IAM role + Pod Identity | `edge` | alb/xalb only |
| ACM certificate + Route53 validation records | `edge` | only with `--alb-route53`/`--xalb-route53`; otherwise you pass `--alb-certificate-arn` |
| ExternalDNS IAM role | `edge` | xalb + Route53 |
| cert-manager Route53 IAM role | `edge` | tailscale |
| Bastion EC2 t3.micro + SG + SSM role | `edge` | optional, no public IP |
| Application Load Balancer | created by ALB controller from the Ingress | alb/xalb |
| Route53 DNS records | ExternalDNS | xalb only |

### 3b. Created only inside Kubernetes (nothing on the AWS side)

OpenSearch, Postgres, Valkey, Benthos, Frontend, Dex, Bifrost, Caddy edge, Argus (Defend), Iris
(Ascend) workloads, per-model vLLM, NVIDIA plugin, Karpenter NodePools/EC2NodeClasses, the
`straiker-credential` and `straiker-secrets` Secrets, mirror/model-sync Jobs.

### 3c. Not created on cloud by the installer

- Customer's own DNS zone (if not Route53 in the same account), corporate network routing (TGW/DX/VPN).
- Tailscale OAuth client (hand-made in Tailscale admin) and the tailnet itself.
- Bedrock model entitlement (customer enables in AWS console).
- Customer's own OIDC IdP, if used instead of the bundled Dex.
- Straiker's side: source ECR, source model bucket, broker Lambda (all in Straiker's us-east-1 account).
- No managed databases: no RDS/Aurora, no ElastiCache, no OpenSearch Service, no MSK/Kinesis, no
  Cognito, no SES, no Secrets Manager, no CloudWatch dashboards.

## 4. On-prem vs SaaS (Frankfurt `prod-euc1`)

| Area | On-prem installer | SaaS (prod-euc1) |
|---|---|---|
| Tenancy | One customer per cluster | Multi-tenant, shared cluster |
| Provisioning | One script, OpenTofu + Helm from operator machine | Terragrunt units (~50) in `infra`, applied by hand/CI |
| Deploy of apps | Helm `upgrade --install` by script | Argo CD + gitops repo (ApplicationSets) |
| Database | In-cluster Postgres 16 StatefulSet (20Gi) | Aurora Postgres serverless (writer + reader) |
| Search/archive | In-cluster single-node OpenSearch | OpenSearch Service domain in its own VPC |
| Cache | In-cluster Valkey | ElastiCache (node-based Redis/Valkey) |
| Streaming | Benthos HTTP to OpenSearch (no broker) | MSK Serverless, Kinesis, ClickHouse Cloud |
| Auth | Dex (static bootstrap admin, optional customer OIDC) | Cognito + triggers resolving from foundation |
| Console/Admin | `straiker-frontend` pod in cluster | Vercel projects pinned to fra1 |
| API gateway | Caddy / ALB / customer ingress | api-gateway service + NLB, custom domains |
| Secrets | K8s Secrets generated by installer | Secrets Manager + External Secrets Operator |
| Images | Mirrored into customer ECR from Straiker via broker Lambda | ECR replication from dev/prod us-east-1 |
| Monitoring | None shipped | Grafana Cloud, otel, Honeycomb |
| Email | None | SES |
| Services included | system, core, inference, defend, ascend only | Also databridge, connect, registry, grid, foundation, portico, surveyor, pathfinder, argus v3, bifrost |
| Nodes | Karpenter, 4 pools; system MNG | Karpenter + GPU pools incl. fallbacks, reserved/agentic pools |
| Network egress | NAT, cross-region pull from us-east-1 on install/upgrade | NAT with fixed egress IP |
| Reachability | Optionally private-only (internal ALB, Tailscale, private API) | Public endpoints |
| Cluster name/account | Customer's account, `s6r-onprem` default | Straiker prod account, `prod-euc1-be` |

Shared design ideas: EKS + Karpenter with arm64 general pools and GPU pools, EKS Pod Identity for IAM,
ALB controller for ingress, the same Argus/Iris images and model set (antman, hulk, quicksilver, thor,
vision, wanda, thanos).

## 5. Takeaways for Frankfurt

- On-prem is a self-contained "everything in the cluster" bundle; SaaS offloads state to managed AWS services.
- Anything the on-prem charts run in-cluster (Postgres, OpenSearch, Valkey, Benthos) is a managed unit in `prod-euc1`.
- Reusable from on-prem for SaaS: NodePool/EC2NodeClass definitions (`charts/straiker-system`), the GPU model
  list, vLLM chart, and Karpenter IAM pattern. Not reusable: the artifact-mirroring Jobs (SaaS uses ECR replication).
