# Straiker on-prem: outbound network allowlist

For network/security teams operating a Straiker on-prem install behind a
restricted egress path (NAT gateway with a firewall policy, a centralized
inspection VPC, or an outbound proxy).

Everything below is outbound TCP/443. Straiker requires no inbound
connectivity from the internet.

Two things use the network from **different places**, and they need different
rules:

| Position | What it is | When it needs egress |
| --- | --- | --- |
| **Operator workstation** | Wherever `install-straiker.sh` runs — a laptop, a jump host, a CI runner | Install and upgrade only |
| **Cluster nodes** | The EKS worker nodes, egressing via NAT | Install and upgrade; a reduced set at steady state |

If your operators run the installer from a corporate workstation that already
has normal internet access, the first table needs no work — only the cluster
side matters.

---

## 1. Operator workstation

The installer resolves Helm charts locally before applying them, so these are
pulled by the operator's machine, not by the cluster.

| Destination | Purpose |
| --- | --- |
| `raw.githubusercontent.com` | Straiker's own Helm chart repository |
| `public.ecr.aws` | Karpenter Helm chart (OCI) |
| `aws.github.io` | AWS Load Balancer Controller chart |
| `kubernetes-sigs.github.io` | ExternalDNS chart |
| `charts.jetstack.io` | cert-manager chart |
| `pkgs.tailscale.com` | Tailscale operator chart — only if `edgeType: tailscale` |
| `*.amazonaws.com` | AWS APIs for OpenTofu and the AWS CLI |

Plus the Kubernetes API server itself. With a private-only API endpoint, AWS
resolves the cluster endpoint through public DNS to its **private** VPC
address, so the workstation needs routed connectivity to the VPC (Transit
Gateway / Direct Connect / VPN) and a cluster security group rule permitting
443 from its source range — not internet access to the endpoint.

## 2. Cluster nodes — install and upgrade windows

Straiker's artifacts are mirrored into your own ECR and S3 during the
`artifacts-sync` phase. That mirroring reads from Straiker's source account in
**us-east-1**.

This traffic cannot be served by VPC endpoints. Interface and gateway
endpoints are regional, so an endpoint in your cluster's region cannot reach a
registry or bucket in `us-east-1`. A real egress path is required during these
windows.

| Destination | Purpose |
| --- | --- |
| `2a7owzgkie5zw6dfl4qqg6tfhe0pqkvb.lambda-url.us-east-1.on.aws` | Straiker artifact broker — issues short-lived, scoped credentials for the two below |
| `631748089429.dkr.ecr.us-east-1.amazonaws.com`<br>`api.ecr.us-east-1.amazonaws.com` | Straiker source container registry |
| `prod-us-east-1-starport-layer-bucket.s3.us-east-1.amazonaws.com` | ECR image layer blobs (AWS-managed bucket backing every ECR pull) |
| `onprem-artifact-models.s3.us-east-1.amazonaws.com` | Straiker source model weights |

**This recurs on every version upgrade,** since upgrades mirror new image
tags. It is not a one-time install requirement.

## 3. Cluster nodes — steady state

Between upgrades, the cluster pulls only from your own in-region ECR and S3.
Everything in this section is same-region and can be served by VPC endpoints
instead of the NAT path if you prefer.

| Destination | Served by endpoint | Purpose |
| --- | --- | --- |
| Your ECR registry | `ecr.api`, `ecr.dkr` | Image pulls |
| `prod-<region>-starport-layer-bucket` | `s3` (gateway, no charge) | ECR image layers |
| Your models bucket | `s3` (gateway, no charge) | Model weights |
| `sts.<region>.amazonaws.com` | `sts` | **Required continuously** — the VPC CNI refreshes IAM credentials here roughly hourly |
| `ec2.<region>.amazonaws.com` | `ec2` | **Required continuously** — VPC CNI pod IP allocation, and Karpenter |
| `ssm.<region>.amazonaws.com` | `ssm` | Karpenter resolves its node AMI through an SSM parameter |
| `eks.<region>.amazonaws.com` | `eks` | `aws eks update-kubeconfig` / DescribeCluster |
| `sqs.<region>.amazonaws.com` | `sqs` | Karpenter interruption queue |
| `elasticloadbalancing.<region>.amazonaws.com` | `elasticloadbalancing` | AWS Load Balancer Controller |
| `logs.<region>.amazonaws.com` | `logs` | CloudWatch Logs |

### LLM provider access

Exactly one of the following, depending on how the install is configured:

| Mode | Destination | Served by endpoint |
| --- | --- | --- |
| `bedrock` | `bedrock-runtime.<region>.amazonaws.com` | `bedrock-runtime` |
| `own-keys` | `api.openai.com`, `api.x.ai`, `api.anthropic.com` (whichever keys are supplied) | No — public internet only |
| `trial-key` | As above, via Straiker's hosted gateway | No — public internet only |

Bedrock is the only mode that can run without internet egress for LLM traffic.
This is also the path worth prioritizing regardless of the rest: inference
traffic carries prompts and model outputs, where container image pulls carry
public artifacts.

---

## If you use VPC endpoints: enable private DNS

An interface endpoint with private DNS **disabled** does not intercept calls
to the standard service hostname. Clients must address the endpoint-specific
name (`vpce-....<service>.<region>.vpce.amazonaws.com`) explicitly, and
nothing in the Straiker stack does — the AWS SDKs all use standard service
names.

AWS documents private DNS as a hard requirement for `ecr.dkr`. The practical
effect is the same for the rest: an endpoint with private DNS off, and no
Route 53 private hosted zone providing equivalent resolution, silently sends
traffic to the public endpoint instead. Verify with:

```
aws ec2 describe-vpc-endpoints --region <region> \
  --filters Name=vpc-id,Values=<vpc-id> \
  --query 'VpcEndpoints[].{Service:ServiceName,PrivateDns:PrivateDnsEnabled}' \
  --output table

aws route53 list-hosted-zones-by-vpc --vpc-id <vpc-id> --vpc-region <region>
```

If private DNS is off, the second command should show a private hosted zone
per service. If it shows neither, that endpoint is not carrying any traffic.

## Removing NAT entirely is not supported

Section 2 requires cross-region egress that no endpoint configuration can
provide. A cluster with no egress path cannot be installed or upgraded. The
supported posture is a controlled egress path — allowlisted, inspected, or
proxied — rather than no egress path.
