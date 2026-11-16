# Straiker on-prem install: customer prerequisites checklist

Give this page to the customer's cloud, network, DNS and security contacts **before** the install call. Every item is something the
installer cannot do for you, or something that makes it stop part-way. If every box is ticked, the install runs in one go
(about 1.5-2 hours, then a hands-off finish). Details and reasons: `doc/data-layer-install-runbook.md`.

Legend: **[Customer]** you do it, **[Straiker]** we do it, **[Both]** agree on it together.

---

## 1. Decisions and details to send us (one week before)

| # | Item | Rule / example | Who |
|---|---|---|---|
| 1.1 | AWS account ID and region | One account, one region. The region must offer the GPU type (`p4d.24xlarge`; the installer checks) | Customer |
| 1.2 | Cluster name | Lowercase, starts with a letter, at most 24 characters (example `acme-prod`) | Customer |
| 1.3 | Resource prefix (`--tf-prefix`) | IAM role names are account-wide. A second install in the same account needs a different prefix | Both |
| 1.4 | Customer name for Straiker | The tenant name we create on our side (`--customer-name`) | Straiker |
| 1.5 | Base domain, and where its DNS lives | `acme.com`. The console is `straiker.`, `straiker-defend.`, `straiker-ascend.<domain>`; the API is `api.<domain>`. See section 4 | Customer |
| 1.6 | Who may reach the product | Allowed IP ranges for the console (`--internal-lb-source-ranges`) and for the API (`--gateway-allowed-cidrs`). The installer warns when the API is public with no ranges | Customer |
| 1.7 | Own VPC or a new one | New VPC (default, `10.0.0.0/16`), or give: VPC ID, private and public subnet IDs. Own-VPC private subnets must already have outbound internet (NAT/IGW) | Customer |
| 1.8 | Products | Ascend, Defend, or both. Defend engine `v3` is needed for the console's Controls page | Both |
| 1.9 | Admin email | First console administrator (a Cognito user is created) | Customer |
| 1.10 | Alarm email(s) | Receive CloudWatch alarms. Each address must click AWS's "Subscription Confirmation" link (manual) | Customer |
| 1.11 | Sign-in method | Google, Facebook, Amazon, Apple, OIDC or SAML: provider, client ID, **client secret**, allowed email domains. The redirect URI we print must be registered with the provider first | Customer |
| 1.12 | Email sending (SES) | Either a sending domain whose DNS you control, or your own verified SES identity ARN plus From address | Customer |
| 1.13 | Bedrock inference profile | `regional` (stays in the geography, recommended for data residency) or `global` | Customer |

Never send secrets by email or chat: the client secret, the AWS keys and the Straiker customer key go through a password manager or
the installer's hidden prompt.

---

## 2. AWS account and access

| # | Item | How to verify | Who |
|---|---|---|---|
| 2.1 | AWS CLI credentials that last 2-3 hours (SSO profile, assumed role or keys). The installer has no login of its own | `aws sts get-caller-identity --profile <p>` prints the right account | Customer |
| 2.2 | The identity can create: IAM roles and service-linked roles, VPC, EC2, EKS, ECR, S3, Aurora, MSK, OpenSearch, ElastiCache, EFS, DynamoDB, KMS, Secrets Manager, Cognito, SES, WAF, ACM, Route 53, CloudWatch, SNS, SQS, EventBridge | Easiest: AdministratorAccess for the install window. No service control policy (SCP) may block these. Missing IAM-role creation is the most common gap | Customer |
| 2.3 | Extra permissions the installer uses: `ec2:RunInstances`/`TerminateInstances` (GPU capacity probe), `ec2:CreateVpc`/`CreateSubnet`/`DeleteSubnet`/`DeleteVpc` (zone probe, own-VPC mode does not need them), `bedrock:InvokeModel` (preflight), `servicequotas:GetServiceQuota` | Part of 2.2 if admin | Customer |
| 2.4 | Bedrock model access granted in the region (console only, once per account): `anthropic.claude-haiku-4-5-20251001-v1:0` and `anthropic.claude-sonnet-4-6`. With Defend v3 also `global.openai.gpt-5.6-sol` and `-terra` | Bedrock console > Model access shows "Access granted". The installer's preflight stops with a clear message if missing | Customer |
| 2.5 | SES production access requested (new accounts are in the sandbox: 200 mails/day, verified recipients only). Cognito sign-up and reset emails need it | `aws sesv2 get-account --query ProductionAccessEnabled` is `true`. Approval takes about a day | Customer |
| 2.6 | No other install uses the same cluster name or prefix in this account and region | Section 1.2 and 1.3 | Customer |

---

## 3. GPU capacity (the step that fails most often)

The models need 10 GPU servers (5 models x 2 replicas). Customers run **2 x `p4d.24xlarge`** (8x A100 each); the pool can grow to 4.

| # | Item | How to verify | Who |
|---|---|---|---|
| 3.1 | EC2 quota "Running On-Demand P instances" (`L-417A185B`) of at least **384 vCPUs** (4 x 96) | `aws service-quotas get-service-quota --service-code ec2 --quota-code L-417A185B --region <r> --query Quota.Value`. Raise: `aws service-quotas request-service-quota-increase --service-code ec2 --quota-code L-417A185B --desired-value 384 --region <r>`. A new account has 0-8; approval takes minutes to days | Customer |
| 3.2 | The region and zone offer `p4d.24xlarge` | `aws ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values=p4d.24xlarge --region <r> --query 'InstanceTypeOfferings[].Location'` | Customer |
| 3.3 | **Reserved capacity** for 2-4 `p4d.24xlarge`: an EC2 Capacity Reservation, or a Capacity Block for ML. Pass its ID as `--gpu-capacity-reservation cr-...`. Without one, on-demand p4d capacity is often unavailable and the install stops early | `aws ec2 describe-capacity-reservations --capacity-reservation-ids cr-... --region <r>`: state `active`, type `p4d.24xlarge`, Linux, default tenancy, right zone. Capacity Blocks you could buy are listed by the installer's first phase | Customer |
| 3.4 | If the reservation was shared from another AWS account, the share is accepted in this account | Visible with the command above | Customer |
| 3.5 | Without a reservation, accept that the installer tries to launch the fleet for about a minute (cost: roughly 1-2 USD for p4d) to find a zone with capacity, and stops before building anything when none has | Skip with `--skip-capacity-probe` | Customer |

---

## 4. Domain, DNS and certificates

| # | Item | Notes | Who |
|---|---|---|---|
| 4.1 | Domain with a **public Route 53 hosted zone in this same account**, and `--domain` equal to that zone's name | Fully automatic: certificates, validation records and every DNS name | Customer |
| 4.2 | If DNS is elsewhere (Cloudflare, corporate DNS, Route 53 in another account) | **Manual**: someone adds the records. The installer prints the certificate validation record early (add it while the rest installs) and later the CNAMEs to the load balancer. They are also saved in `~/.straiker/gateway-dns-handoff-<cluster>.md` for the DNS admin. Supply an ISSUED ACM certificate for the three console names with `--certificate-arn` | Customer |
| 4.3 | Own certificate for the API | `--gateway-cert-arn` (ISSUED, same region) | Customer |
| 4.4 | SES sending domain: the DNS records the installer prints (DKIM, mail-from) are added if the zone is not in this account | Needed before Cognito email works | Customer |
| 4.5 | Sign-in provider: redirect URI `https://<prefix>.auth.<region>.amazoncognito.com/oauth2/idpresponse` registered, OAuth consent screen set (Google: Internal for a Workspace-only audience), scopes `openid email profile` | The installer writes a hand-off sheet with the exact values: `~/.straiker/sso-handoff-<cluster>.md` | Customer |

---

## 5. Network and egress

The product needs **no inbound access** except the load balancer's ports 443 from the ranges you allow. Cluster nodes need outbound
TCP/443 (full list in `doc/egress-allowlist.md`).

| # | Item | Why | Who |
|---|---|---|---|
| 5.1 | Outbound to Straiker's artifact source in **us-east-1** during install and every upgrade: broker `2a7owzgkie5zw6dfl4qqg6tfhe0pqkvb.lambda-url.us-east-1.on.aws`, ECR `631748089429.dkr.ecr.us-east-1.amazonaws.com`, `api.ecr.us-east-1.amazonaws.com`, `prod-us-east-1-starport-layer-bucket.s3.us-east-1.amazonaws.com`, `onprem-artifact-models.s3.us-east-1.amazonaws.com` | Images and model weights are copied into your ECR and S3. VPC endpoints cannot reach another region, so a real NAT/proxy path is needed. Removing NAT entirely is not supported | Customer |
| 5.2 | Operator workstation reaches `raw.githubusercontent.com`, `public.ecr.aws`, `aws.github.io`, `kubernetes-sigs.github.io`, `charts.jetstack.io`, Docker Hub and `*.amazonaws.com` | Helm charts and probe images | Customer |
| 5.3 | Steady-state, in-region: `sts`, `ec2`, `ssm`, `eks`, `sqs`, `elasticloadbalancing`, `logs`, `bedrock-runtime`, your ECR and S3. With interface endpoints, **private DNS must be on** | The VPC CNI needs STS and EC2 continuously, or nodes degrade about an hour in | Customer |
| 5.4 | If the EKS API is private-only: the operator workstation has routed access to the VPC (VPN, Direct Connect, Transit Gateway) and a security-group rule for 443 from its range | `--private-api-endpoint` | Customer |
| 5.5 | Free address space for the cluster. Default VPC `10.0.0.0/16` must not overlap networks you connect to | One `/24` private subnet is small: use more zones (`ha`) or your own larger subnets for anything beyond a test | Customer |

---

## 6. Operator workstation

| # | Item | Notes |
|---|---|---|
| 6.1 | macOS or Linux shell with `aws` (v2), `kubectl`, `helm`, `python3`, `curl`, and `crane` (`brew install crane`). OpenTofu is downloaded by the installer | `scripts/install-data-layer.sh --check` runs the pre-flight only |
| 6.2 | Stays awake and connected for 2-3 hours (use `tmux` or `screen`), disk space for the installer bundle | A laptop that sleeps breaks the run; re-running the same command resumes |
| 6.3 | A hidden-input terminal for the Straiker customer key and the sign-in client secret (`SSO_CLIENT_SECRET`) | Never put them in command-line flags or shell history |
| 6.4 | Do not edit the installer scripts during a run. When running more than one install from one machine, set `STRAIKER_STATE_FILE` per install | |

---

## 7. What Straiker does before the call [Straiker]

- Creates the customer entry and API key in the artifact account and gives you the key through a secure channel.
- Confirms every image the release pins is published, and the model weights are in the source bucket.
- Confirms the installer version and the api-gateway image the install will pin.
- Rotates the key after the install if it was ever pasted into a chat or a shell history.

---

## 8. Day-of sign-off

All of these should be answered "yes" before pressing Enter:

- [ ] `aws sts get-caller-identity` shows the right account, and the login lasts 3 hours
- [ ] P-instance quota is 384 vCPUs or more, and `p4d.24xlarge` is offered in the chosen zones
- [ ] A capacity reservation exists and is `active` (or the customer accepts the capacity probe)
- [ ] Bedrock model access shows granted for the two Claude models (and the gpt-5.6 pair for Defend v3)
- [ ] SES production access is on, or the sandbox is accepted for the first day (verified recipients only)
- [ ] The Route 53 zone is in this account, or the DNS admin is on call for the two records
- [ ] The sign-in redirect URI is registered at the identity provider
- [ ] Outbound HTTPS to the us-east-1 addresses in 5.1 is allowed from the cluster's subnets
- [ ] The customer key is at hand, and the workstation will not sleep
- [ ] Everyone knows a pause ("blocked") is not a failure: fix the named item and run the same command again

## 9. The command

```bash
scripts/install-data-layer.sh \
  --cluster-name <name> --region <region> --customer-name <customer> --tf-prefix <prefix> \
  --profile <aws-profile> --expect-account <account-id> \
  --domain <customer.com> --route53 \
  --gpu-fleet p4d --gpu-capacity-reservation cr-... \
  --alarm-email <ops@customer.com> \
  --installer-arg --admin-email --installer-arg <admin@customer.com> \
  --ses-domain <customer.com> \
  --sso-type google --sso-client-id <id> --sso-domains customer.com \
  --customer-key-file ./key.txt --yes
```

Without a Route 53 zone in the account use `--certificate-arn <arn>` instead of `--route53`. Run `--check` first.
