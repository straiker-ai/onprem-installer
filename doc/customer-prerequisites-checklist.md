# Straiker on-prem install: customer prerequisites checklist

Give this page to the customer's cloud, network, DNS and security contacts **before** the install call. Every item is something the
installer cannot do for you, or something that makes it stop part-way. If every box is ticked, the install runs in one go
(about 1.5-2 hours, then a hands-off finish).

Legend: **[Customer]** you do it, **[Straiker]** we do it, **[Both]** agree on it together.

---

## 1. Decisions and details to send us (one week before)

| # | Item | Rule / example | Who |
|---|---|---|---|
| 1.1 | AWS account ID and region | One account, one region. The region must offer the GPU type (`p4d.24xlarge`; the installer checks) | Customer |
| 1.2 | Cluster name | Lowercase, starts with a letter, at most 24 characters (example `acme-prod`) | Customer |
| 1.3 | Resource prefix (`--tf-prefix`) | IAM role names are account-wide. A second install in the same account needs a different prefix | Both |
| 1.4 | Customer name for Straiker | The tenant name we create on our side (`--customer-name`) | Straiker |
| 1.5 | Base domain, and where its DNS lives | `acme.com`. The console URL will be `straiker.<domain>`. See section 4 | Customer |
| 1.6 | Who may reach the product | Allowed IP ranges for the console (`--internal-lb-source-ranges`) and for the API (`--gateway-allowed-cidrs`). The installer warns when the API is public with no ranges | Customer |
| 1.7 | Own VPC or a new one | New VPC (default, `10.0.0.0/16`), or give: VPC ID, private and public subnet IDs. Own-VPC private subnets must already have outbound internet (NAT/IGW) | Customer |
| 1.8 | Products | Ascend, Defend, or both. Defend engine `v3` is needed for the console's Controls page | Both |
| 1.9 | Admin email | First console administrator (a Cognito user is created) | Customer |
| 1.10 | Alarm email(s) | Receive CloudWatch alarms. Each address must click AWS's "Subscription Confirmation" link (manual) | Customer |
| 1.11 | Sign-in method | Google, Facebook, Amazon, Apple, OIDC or SAML: provider, client ID, **client secret**, allowed email domains. The redirect URI we print must be registered with the provider first | Customer |
| 1.12 | Email sending (SES) | Either a sending domain whose DNS you control, or your own verified SES identity ARN plus From address | Customer |
| 1.13 | Bedrock inference profile | `regional` (stays in the geography, recommended for data residency) or `global` | Customer |
| 1.14 | Production grade (high availability)? | **Yes**: `ha` (2 zones) or `max` (3 zones): replicas spread over zones, survives the loss of one zone, needs GPU capacity in each zone. **No** (trial or test): `min`, one zone, cheaper, a zone outage stops the product. Chosen on the first run, cannot be changed later | Customer |

Never send secrets by email or chat: the client secret, the AWS keys and the Straiker customer key go through a password manager or
the installer's hidden prompt.

---

## 2. AWS account and access

| # | Item | How to verify | Who |
|---|---|---|---|
| 2.1 | AWS CLI credentials that last 2-3 hours (SSO profile, assumed role or keys). The installer has no login of its own | `aws sts get-caller-identity --profile <p>` prints the right account | Customer |
| 2.2 | The identity can create: IAM roles and service-linked roles, VPC, EC2, EKS, ECR, S3, Aurora, MSK, OpenSearch, ElastiCache, EFS, DynamoDB, KMS, Secrets Manager, Cognito, SES, WAF, ACM, Route 53, CloudWatch, SNS, SQS, EventBridge | Easiest: AdministratorAccess for the install window. No service control policy (SCP) may block these. Missing IAM-role creation is the most common gap | Customer |
| 2.3 | Extra permissions the installer uses: `ec2:RunInstances`/`TerminateInstances` (GPU capacity probe), `ec2:CreateVpc`/`CreateSubnet`/`DeleteSubnet`/`DeleteVpc` (zone probe, own-VPC mode does not need them), `bedrock:InvokeModel` (preflight), `servicequotas:GetServiceQuota` | Part of 2.2 if admin | Customer |
| 2.4 | Bedrock models usable in the region: `anthropic.claude-haiku-4-5-20251001-v1:0` and `anthropic.claude-sonnet-4-6`. With Defend v3 also `global.openai.gpt-5.6-sol` and `-terra`. The old "Model access" page is retired: models switch on automatically at first use. Anthropic may ask first-time accounts for a short use-case form (Bedrock console > Model catalog > open the model in the playground). No IAM policy or Organizations SCP may deny `bedrock:InvokeModel` | Open each model in the Bedrock playground once and get an answer. The installer's preflight makes a real call and stops with a clear message if it fails | Customer |
| 2.5 | SES production access requested (new accounts are in the sandbox: 200 mails/day, verified recipients only). Cognito sign-up and reset emails need it | `aws sesv2 get-account --query ProductionAccessEnabled` is `true`. Approval takes about a day | Customer |
| 2.6 | No other install uses the same cluster name or prefix in this account and region | Section 1.2 and 1.3 | Customer |

**2.5 How to request SES production access** (once per account and region; use the install region)

- **Step 1.** Sign in to the AWS console as an administrator and select the install region. SES access is per region.
- **Step 2.** Open **Amazon SES > Account dashboard**. A yellow banner says the account is in the sandbox. Choose **Request production access**.
- **Step 3.** Fill in the form: **Mail type** `Transactional`; **Website URL** your company site; **Use case description** as below; **Additional contacts** a monitored mailbox; **Acknowledge** the AWS policies.
- **Step 4.** Submit. AWS replies by email, usually within 24 hours. If they ask for more detail, answer on the same support case.
- **Step 5.** Check that it worked with the command below. It must print `true`.

Suggested use case text: *"Transactional email only, sent by the Straiker AI security platform running in our own AWS account: sign-up verification, password reset and account notifications for our staff, a few hundred messages a month. Recipients are our own employees who asked for an account. We do not send marketing mail. Bounces and complaints are monitored through SES and handled the same day."*

```bash
# Instead of Steps 2-4, the same request from the command line
aws sesv2 put-account-details --production-access-enabled --mail-type TRANSACTIONAL \
  --website-url https://<your-company-site> --contact-language EN \
  --additional-contact-email-addresses <ops@your-company.com> \
  --use-case-description "<the text above>" --region <r> --profile <profile>

# Check (true = approved)
aws sesv2 get-account --region <r> --profile <profile> --query ProductionAccessEnabled
```

Requesting access is separate from verifying the sending domain (section 1.12), which the installer handles.

---

## 3. GPU capacity (the step that fails most often)

The models need 10 GPU servers (5 models x 2 replicas). Customers run **2 x `p4d.24xlarge`** (8x A100 each); the pool can grow to 4.

| # | Item | How to verify | Who |
|---|---|---|---|
| 3.1 | EC2 quota "Running On-Demand P instances" (`L-417A185B`) of at least **384 vCPUs** (4 x 96) | `aws service-quotas get-service-quota --service-code ec2 --quota-code L-417A185B --region <r> --query Quota.Value`. Raise: `aws service-quotas request-service-quota-increase --service-code ec2 --quota-code L-417A185B --desired-value 384 --region <r>`. A new account has 0-8; approval takes minutes to days | Customer |
| 3.2 | The region and zone offer `p4d.24xlarge` | `aws ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values=p4d.24xlarge --region <r> --query 'InstanceTypeOfferings[].Location'` | Customer |
| 3.3 | **Reserved capacity** for 2-4 `p4d.24xlarge`: an EC2 Capacity Reservation, or a Capacity Block for ML. Pass its ID as `--gpu-capacity-reservation cr-...`. Without one, on-demand p4d capacity is often unavailable and the install stops early | `aws ec2 describe-capacity-reservations --capacity-reservation-ids cr-... --region <r>`: state `active`, type `p4d.24xlarge`, Linux, default tenancy, right zone. Capacity Blocks you could buy are listed by the installer's first phase | Customer |
| 3.4 | If the reservation was shared from another AWS account, the share is accepted in this account | Accept any pending share: `aws ram get-resource-share-invitations --region <r> --query "resourceShareInvitations[?status=='PENDING'].[resourceShareInvitationArn,resourceShareName]" --output table`, then `aws ram accept-resource-share-invitation --region <r> --resource-share-invitation-arn <arn>`. Prove it is visible: `aws ec2 describe-capacity-reservations --capacity-reservation-ids cr-... --region <r> --query 'CapacityReservations[].[CapacityReservationId,OwnerId,State,InstanceType,AvailabilityZone,AvailableInstanceCount]' --output table` shows the row (`OwnerId` is the other account) with state `active` | Customer |
| 3.5 | Without a reservation, accept that the installer tries to launch the fleet for about a minute per zone (cost: roughly 1-2 USD for p4d) to pick a zone with capacity before building, and then waits up to 6 hours for GPU nodes if capacity is short | Skip with `--skip-capacity-probe` | Customer |

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

The Straiker servers sit in a private network with no direct line to the internet. To install and upgrade, they must **reach out**
(*egress*) to a few named addresses over HTTPS (port 443). Nobody needs to reach in, except your own users opening the website.
Your network team opens these doors in the firewall, proxy or AWS NAT gateway (the shared exit for private servers).

| # | What | Why (plain words) | What to allow or arrange | Pass looks like |
|---|---|---|---|---|
| 5.1 | **Straiker's software source** (US East, N. Virginia) | Images and AI models are copied from Straiker's account into yours. AWS private links cannot cross regions, so the normal internet path is needed. **Repeats at every upgrade** | Outbound 443 to the 5 addresses in check 5.1 | 5 lines `OK` |
| 5.2 | **The installer's computer** | It downloads the deployment recipes and talks to AWS | Outbound 443 to GitHub, `public.ecr.aws`, `aws.github.io`, `kubernetes-sigs.github.io`, `charts.jetstack.io`, Docker Hub, `*.amazonaws.com` | All `OK`, and your AWS account number is printed |
| 5.3 | **AWS services in your region** | The cluster talks to them all the time. If `sts` or `ec2` is cut off, servers start failing after about 1 hour with no clear error | Outbound 443 to the 11 addresses in check 5.3, **or** VPC endpoints with **private DNS switched on** | All `OK`; every endpoint shows `PrivateDns True` |
| 5.4 | **Private-only cluster API** (only with `--private-api-endpoint`) | The cluster's management address is hidden inside your network, so the installer's computer needs a route in | VPN, Direct Connect or Transit Gateway to the VPC, and a rule allowing 443 from that computer | `kubectl get nodes` lists the nodes |
| 5.5 | **No address clash** | The new network uses `10.0.0.0/16`. An overlap with your company ranges breaks traffic and cannot be fixed later | Compare with your ranges; tell us a free range if it clashes | Network team confirms no overlap |
| 5.6 | **Own VPC: a way out** (only with `--vpc-id`) | In this mode we create no NAT or internet route. Without one, servers cannot fetch software and fail about an hour in | Each private subnet routes `0.0.0.0/0` to a NAT or your firewall, with free addresses | Route is `active`; 200 or more free addresses |
| 5.7 | **Users can reach the product** | Staff open `straiker.<domain>`, apps call `api.<domain>`. Wrong allowed ranges or a firewall make "the site does not load" | Office and server ranges are in `--internal-lb-source-ranges` (website) and `--gateway-allowed-cidrs` (API); outbound 443 to the 4 names | 4 lines `OK` (a login page or auth error is normal) |
| 5.8 | **Own LLM keys** (only if not using Bedrock) | Prompts and answers go to the provider's public service | Outbound 443 to `api.openai.com`, `api.x.ai`, `api.anthropic.com` (only those you use) | Not `000` |

**Where to run the checks:** from a machine behind the **same firewall or proxy as the cluster**: best a small temporary EC2 test server in
the private subnet (open it with AWS Session Manager, delete it afterwards). A laptop on another network can pass what the cluster fails.
**Reading results:** any answer (even 403 or 404) means the door is **open**. `BLOCKED` (code `000`) means a firewall dropped it, the name
did not resolve, or a device that inspects encrypted traffic rejected it (tell us if you inspect HTTPS).

First define the checker once on the test machine:

```bash
chk(){ for h in "$@"; do c=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "https://$h/"); [ "$c" = 000 ] && echo "BLOCKED  $h" || echo "OK ($c)  $h"; done; }
R=<region>; A=<account-id>; D=<your-domain>
```

**Checks**

```bash
# 5.1 Straiker's us-east-1 source
chk 2a7owzgkie5zw6dfl4qqg6tfhe0pqkvb.lambda-url.us-east-1.on.aws 631748089429.dkr.ecr.us-east-1.amazonaws.com \
    api.ecr.us-east-1.amazonaws.com prod-us-east-1-starport-layer-bucket.s3.us-east-1.amazonaws.com \
    onprem-artifact-models.s3.us-east-1.amazonaws.com

# 5.2 Installer's computer (run on that computer)
chk raw.githubusercontent.com public.ecr.aws aws.github.io kubernetes-sigs.github.io charts.jetstack.io \
    registry-1.docker.io auth.docker.io sts.amazonaws.com
aws sts get-caller-identity --profile <profile>

# 5.3 AWS services in your region
chk sts.$R.amazonaws.com ec2.$R.amazonaws.com ssm.$R.amazonaws.com eks.$R.amazonaws.com sqs.$R.amazonaws.com \
    elasticloadbalancing.$R.amazonaws.com logs.$R.amazonaws.com bedrock-runtime.$R.amazonaws.com \
    api.ecr.$R.amazonaws.com $A.dkr.ecr.$R.amazonaws.com s3.$R.amazonaws.com
# only if you use VPC endpoints: every row must say PrivateDns True
aws ec2 describe-vpc-endpoints --region $R --filters Name=vpc-id,Values=<vpc-id> \
  --query 'VpcEndpoints[].{Service:ServiceName,PrivateDns:PrivateDnsEnabled}' --output table

# 5.4 Private-only API (after the cluster exists)
aws eks update-kubeconfig --name <cluster> --region $R --profile <profile> && kubectl get nodes

# 5.5 Address clash: list the network ranges already in the account, compare with your company ranges
aws ec2 describe-vpcs --region $R --profile <profile> --query 'Vpcs[].[VpcId,CidrBlock]' --output table

# 5.6 Own VPC (repeat per private subnet): needs an active 0.0.0.0/0 route and free addresses
aws ec2 describe-route-tables --region $R --filters Name=association.subnet-id,Values=<subnet-id> \
  --query 'RouteTables[].Routes[?DestinationCidrBlock==`0.0.0.0/0`]' --output json
aws ec2 describe-subnets --region $R --subnet-ids <subnet-id> --query 'Subnets[].[SubnetId,CidrBlock,AvailableIpAddressCount]' --output table

# 5.7 Users can reach the product (run from a user's computer and an application server, after the install)
chk straiker.$D straiker-defend.$D straiker-ascend.$D api.$D

# 5.8 Own LLM keys only
chk api.openai.com api.x.ai api.anthropic.com
```

**Fail means:** a `BLOCKED` line: send that address to the network team. In 5.6 an empty list `[]` or state `blackhole` means the route is missing or broken.

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
- [ ] Bedrock answers in the playground for the two Claude models (and the gpt-5.6 pair for Defend v3); no policy or SCP denies `bedrock:InvokeModel`
- [ ] SES production access is on, or the sandbox is accepted for the first day (verified recipients only)
- [ ] The Route 53 zone is in this account, or the DNS admin is on call for the two records
- [ ] The sign-in redirect URI is registered at the identity provider
- [ ] Every check in section 5 passed (5.1 the us-east-1 addresses, 5.2 the installer's computer, 5.3 in-region AWS services, 5.4-5.6 as they apply)
- [ ] The customer key is at hand, and the workstation will not sleep
- [ ] Everyone knows a pause ("blocked") is not a failure: fix the named item and run the same command again

## 9. The command

> **The command below is only a sample, not the one to run.** The real command is built from the answers to section 1 (and the
> reservation from section 3): each answer becomes one or more flags, as the table shows. Leave out any flag whose answer is "default".
> Straiker builds the final command with you on the pre-install call, and `--check` proves it before anything is created.

| Section 1 answer | Becomes this flag |
|---|---|
| 1.1 Region / account ID | `--region <region>` and `--expect-account <account-id>` (stops if the wrong account is logged in); the login itself is `--profile <aws-profile>` |
| 1.2 Cluster name | `--cluster-name <name>` |
| 1.3 Resource prefix | `--tf-prefix <prefix>` |
| 1.4 Customer name | `--customer-name <customer>`; the key goes in `--customer-key-file ./key.txt` (or a hidden prompt) |
| 1.5 Base domain | `--domain <customer.com>`, plus `--route53` when its public zone is in this account, **or** `--certificate-arn <arn>` when DNS is elsewhere (then DNS records are added by hand, section 4) |
| 1.6 Who may reach the product | `--installer-arg --internal-lb-source-ranges --installer-arg <cidr>` (website) and `--installer-arg --gateway-allowed-cidrs --installer-arg <cidr,cidr>` (API). A private API: `--installer-arg --gateway-exposure --installer-arg internal` |
| 1.7 Own VPC or new | New VPC: nothing to add (optionally `--availability-zones a,b`). Own VPC: `--installer-arg --vpc-id --installer-arg <vpc-id> --installer-arg --private-subnet-ids --installer-arg <ids> --installer-arg --public-subnet-ids --installer-arg <ids>` |
| 1.8 Products | `--products ascend,defend` (default both) and `--defend-engine v3` (default) |
| 1.9 Admin email | `--installer-arg --admin-email --installer-arg <admin@customer.com>` |
| 1.10 Alarm email(s) | `--alarm-email <ops@customer.com>` (repeat per address) |
| 1.11 Sign-in method | `--sso-type <google\|facebook\|amazon\|apple\|saml\|oidc>`, `--sso-client-id <id>`, `--sso-domains <customer.com>`; `saml`/`oidc` also `--sso-name`, `--sso-saml-metadata-url` or `--sso-oidc-issuer`. The client secret is **not** a flag: set `SSO_CLIENT_SECRET` or type it at the hidden prompt |
| 1.12 Email sending | `--ses-domain <customer.com>`, **or** `--ses-identity-arn <arn> --ses-from <address>` |
| 1.13 Bedrock profile | No flag: the installer asks once on the first run (`regional` or `global`) |
| 1.14 Production grade | `--provision-strategy <min\|ha\|max>` (default `min`; use `ha` or `max` for production) |
| Section 3 GPU capacity | `--gpu-fleet p4d` (default for customers) and `--gpu-capacity-reservation cr-...` |

Sample (illustrative values only):

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

Run the same command with `--check` first (pre-flight only, nothing is created), then without it.
