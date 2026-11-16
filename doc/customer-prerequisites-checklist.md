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

**In plain words.** The Straiker servers run inside a private network in your AWS account. A private network has no direct line to the
internet, by design. During the install, and again whenever Straiker is upgraded, those servers must **reach out** to a few named
internet addresses to fetch software and AI model files. Reaching out is called *egress*. We never need anyone on the internet to
reach in, apart from your own users opening the Straiker website through the load balancer.

Your network or security team controls which addresses are allowed out (a firewall, a proxy, or AWS's "NAT gateway", which is the
shared door through which private servers reach the internet). This section lists every address and rule, why it is needed, and a
check that proves it works. All checks use `HTTPS` (port 443). Nothing else is required.

**Where to run the checks.** Run each check from a computer that sits **behind the same firewall or proxy as the cluster will**:
ideally a small temporary test server (an EC2 instance) in the cluster's private subnet, opened with AWS Session Manager, or any
machine the network team confirms uses the same outbound rules. A laptop on a different network can pass a check that the cluster
would fail. Delete the test server afterwards.

**How to read the results.** The checks use `curl`. Any answer from the other side (even "403 Forbidden" or "404 Not Found") means the
door is **open**: the address was reached, and we only need to reach it, not log in. The code `000` means **blocked or unreachable**
(a firewall dropped it, the name did not resolve, or a security device that inspects encrypted traffic rejected the connection; if your
firewall inspects HTTPS, tell us, because the inspecting certificate may have to be trusted).

### 5.1 Straiker's artifact source in us-east-1 (during install and every upgrade)

- **What it is:** Straiker keeps its software images and AI model files in Straiker's own AWS account, in the US East (N. Virginia)
  region. During install the cluster copies them into **your** account. After that the cluster uses only your copies.
- **Why it needs the internet:** AWS private connections ("VPC endpoints") only work inside one region. Your cluster may be in
  another region, so the copy has to go over the normal internet path. Removing the NAT or internet path entirely is not supported.
- **What to allow (outbound, HTTPS 443):**
  - `2a7owzgkie5zw6dfl4qqg6tfhe0pqkvb.lambda-url.us-east-1.on.aws` (hands out short-lived, limited access passes)
  - `631748089429.dkr.ecr.us-east-1.amazonaws.com` and `api.ecr.us-east-1.amazonaws.com` (Straiker's software images)
  - `prod-us-east-1-starport-layer-bucket.s3.us-east-1.amazonaws.com` (the file storage behind every AWS image download)
  - `onprem-artifact-models.s3.us-east-1.amazonaws.com` (the AI model files)
- **Needed again:** at every Straiker version upgrade, not only the first install.
- **Check:** from the test server run:

  ```bash
  for h in 2a7owzgkie5zw6dfl4qqg6tfhe0pqkvb.lambda-url.us-east-1.on.aws \
           631748089429.dkr.ecr.us-east-1.amazonaws.com \
           api.ecr.us-east-1.amazonaws.com \
           prod-us-east-1-starport-layer-bucket.s3.us-east-1.amazonaws.com \
           onprem-artifact-models.s3.us-east-1.amazonaws.com; do
    code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "https://$h/")
    if [ "$code" = "000" ]; then echo "BLOCKED  $h"; else echo "OK ($code)  $h"; fi
  done
  ```

  **Pass:** five lines starting with `OK`. **Fail:** any `BLOCKED` line: send that address to the network team to allow.

### 5.2 The installer's own computer (the "operator workstation")

- **What it is:** the laptop, jump server or CloudShell session where the install command is run.
- **Why it needs the internet:** the installer downloads its deployment recipes ("Helm charts") on that computer before applying them,
  plus the AWS tools talk to AWS.
- **What to allow (outbound, HTTPS 443):** `raw.githubusercontent.com` (Straiker's recipes), `public.ecr.aws` (autoscaling software),
  `aws.github.io` (load balancer software), `kubernetes-sigs.github.io` (DNS automation), `charts.jetstack.io` (certificate software),
  Docker Hub (`registry-1.docker.io`, `auth.docker.io`, `production.cloudflare.docker.com`; used by small verification pods), and
  `*.amazonaws.com` (all AWS services). `pkgs.tailscale.com` only if you choose the Tailscale edge.
- **Check:** from the installer's computer:

  ```bash
  for h in raw.githubusercontent.com public.ecr.aws aws.github.io kubernetes-sigs.github.io charts.jetstack.io \
           registry-1.docker.io auth.docker.io sts.amazonaws.com; do
    code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "https://$h/")
    if [ "$code" = "000" ]; then echo "BLOCKED  $h"; else echo "OK ($code)  $h"; fi
  done
  aws sts get-caller-identity --profile <profile>
  ```

  **Pass:** all `OK`, and the last command prints the customer's AWS account number. **Fail:** a `BLOCKED` line (allow that address) or an
  AWS error (the login or permissions are the problem, see section 2).

### 5.3 AWS services the cluster talks to all the time (steady state, in your own region)

- **What it is:** once installed, the servers keep talking to a handful of AWS services in **your** region: security tokens, server
  management, load balancer control, logs, and the AI service (Bedrock).
- **Why it matters:** two of them are needed **continuously**, not just at install. If the security-token service (`sts`) or the
  server service (`ec2`) cannot be reached, the cluster's network layer loses its permissions after about an hour and the servers
  start failing, with nothing in the product pointing at the cause.
- **What to allow (outbound, HTTPS 443, replace `<region>` with your region, for example `us-west-2`):**
  `sts.<region>.amazonaws.com`, `ec2.<region>.amazonaws.com`, `ssm.<region>.amazonaws.com`, `eks.<region>.amazonaws.com`,
  `sqs.<region>.amazonaws.com`, `elasticloadbalancing.<region>.amazonaws.com`, `logs.<region>.amazonaws.com`,
  `bedrock-runtime.<region>.amazonaws.com`, your own image registry (`<account>.dkr.ecr.<region>.amazonaws.com`, `api.ecr.<region>.amazonaws.com`)
  and S3 in your region (`s3.<region>.amazonaws.com`).
- **Two ways to allow them:** let them out through the NAT/firewall (simplest), or create AWS "VPC endpoints" so the traffic never
  leaves AWS. If you use endpoints, **private DNS must be switched on** for each one; otherwise the traffic silently goes the public
  way and fails if that is blocked.
- **Check:** from the test server (set `R` to your region):

  ```bash
  R=<region>; A=<account-id>
  for h in sts.$R.amazonaws.com ec2.$R.amazonaws.com ssm.$R.amazonaws.com eks.$R.amazonaws.com sqs.$R.amazonaws.com \
           elasticloadbalancing.$R.amazonaws.com logs.$R.amazonaws.com bedrock-runtime.$R.amazonaws.com \
           api.ecr.$R.amazonaws.com $A.dkr.ecr.$R.amazonaws.com s3.$R.amazonaws.com; do
    code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "https://$h/")
    if [ "$code" = "000" ]; then echo "BLOCKED  $h"; else echo "OK ($code)  $h"; fi
  done
  ```

  **Pass:** all `OK`. If you use VPC endpoints, also run these two checks; every endpoint must show `PrivateDns` as `True`:

  ```bash
  aws ec2 describe-vpc-endpoints --region <region> --filters Name=vpc-id,Values=<vpc-id> \
    --query 'VpcEndpoints[].{Service:ServiceName,PrivateDns:PrivateDnsEnabled}' --output table
  nslookup sts.<region>.amazonaws.com
  ```

  The `nslookup` answer should be a private address (starting `10.`, `172.16-31.` or `192.168.`) when a private endpoint serves it.
  **Fail:** a `BLOCKED` line, or `PrivateDns` `False` with no matching private DNS zone.

### 5.4 Private-only Kubernetes control address (only if you choose `--private-api-endpoint`)

- **What it is:** the cluster has a management address (the "API server") used by the installer. By default it is reachable from the
  internet but protected by AWS login. A **private-only** setting hides it inside your network.
- **Why it matters:** with the private setting, the installer's computer must be on a network route into the VPC (VPN, Direct Connect
  or Transit Gateway), or it can not finish the install.
- **What to arrange:** a routed connection from the installer's computer to the VPC, and a firewall (security group) rule that
  allows port 443 from that computer's address range to the cluster.
- **Check (after the cluster exists):**

  ```bash
  aws eks describe-cluster --name <cluster> --region <region> --profile <profile> \
    --query 'cluster.{private:resourcesVpcConfig.endpointPrivateAccess,public:resourcesVpcConfig.endpointPublicAccess,endpoint:endpoint}'
  aws eks update-kubeconfig --name <cluster> --region <region> --profile <profile>
  kubectl get nodes
  ```

  **Pass:** `kubectl get nodes` lists the nodes. For a private-only cluster, `private` is `true` and `public` is `false`.
  **Fail:** `kubectl` hangs or times out: the route into the VPC or the 443 rule is missing.
- **Check (before the install, to avoid surprises):** from the installer's computer, confirm a private address in the VPC answers on
  443, for example `nc -vz <private-ip-in-the-vpc> 443`, or ask the network team to confirm the VPN or Direct Connect route to the VPC range.

### 5.5 Free address space (the network ranges must not clash)

- **What it is:** every network has a range of addresses. The new VPC uses `10.0.0.0/16` by default. If your company network already
  uses that range, or you connect this VPC to other networks (VPN, peering), traffic between them breaks.
- **Why it matters:** an overlap cannot be fixed after the cluster exists.
- **What to do:** compare the range with your company's ranges. If it clashes, tell us a free range before the install (or bring your
  own VPC, 5.6). Also note that the default layout uses one small private subnet (a `/24`, about 250 addresses); for anything beyond
  a test use more zones (`ha`) or your own larger subnets.
- **Check:**

  ```bash
  aws ec2 describe-vpcs --region <region> --profile <profile> --query 'Vpcs[].[VpcId,CidrBlock,IsDefault]' --output table
  ```

  **Pass:** the network team confirms `10.0.0.0/16` (or your agreed range) does not overlap with anything this VPC will connect to.
  **Fail:** an overlap: agree a different range first.

### 5.6 Bring your own VPC: the private subnets must already reach the internet

(Only if you use `--vpc-id`.)

- **What it is:** if you give us your own network, the installer **does not** create a NAT gateway or an internet route. Your
  private subnets must already have a way out.
- **Why it matters:** without it the servers cannot fetch their software, and they may degrade about an hour later when they cannot
  refresh their AWS permissions. Nothing in the install output would name the cause.
- **What to arrange:** each private subnet has a route to a NAT gateway (or your firewall) for `0.0.0.0/0`, and has free addresses.
- **Check** (repeat for every private subnet):

  ```bash
  aws ec2 describe-route-tables --region <region> --profile <profile> \
    --filters Name=association.subnet-id,Values=<private-subnet-id> \
    --query 'RouteTables[].Routes[?DestinationCidrBlock==`0.0.0.0/0`]' --output json
  aws ec2 describe-subnets --region <region> --profile <profile> --subnet-ids <private-subnet-id> \
    --query 'Subnets[].[SubnetId,AvailabilityZone,CidrBlock,AvailableIpAddressCount]' --output table
  ```

  **Pass:** the first command shows a route with a `NatGatewayId` (or your appliance) and state `active`; the second shows plenty of
  free addresses (at least 200 for a small install). **Fail:** an empty list `[]` for the first command, or a `blackhole` state: add or
  repair the route. The installer also checks this itself and stops with a message before building anything.

### 5.7 Your users can reach the Straiker website and API

- **What it is:** your staff open `https://straiker.<your-domain>` and your applications call `https://api.<your-domain>`. Both go to the
  load balancer in your account, over HTTPS 443.
- **Why it matters:** a corporate firewall or proxy that blocks the new names, or the allowed-address list (`--internal-lb-source-ranges`
  for the website, `--gateway-allowed-cidrs` for the API) missing an office or server range, shows up as "the site does not load".
- **What to arrange:** the office and server networks that need access are in the allowed ranges you gave us, and outbound HTTPS to the
  four names (`straiker.`, `straiker-defend.`, `straiker-ascend.` and `api.<your-domain>`) is permitted.
- **Check (after the install):** from a user's computer and from an application server:

  ```bash
  for h in straiker straiker-defend straiker-ascend api; do
    code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "https://$h.<your-domain>/")
    if [ "$code" = "000" ]; then echo "BLOCKED  $h.<your-domain>"; else echo "OK ($code)  $h.<your-domain>"; fi
  done
  ```

  **Pass:** four `OK` lines (a login page or an authentication error code is normal). **Fail:** `BLOCKED` from a network that should have access:
  check the allowed ranges, the DNS records (section 4) and the firewall.

### 5.8 Only if you do not use Amazon Bedrock for the AI provider

- **What it is:** by default the AI calls go to Amazon Bedrock inside AWS (5.3 covers it). If you instead choose your own keys, the
  cluster must reach the provider's public service.
- **What to allow:** `api.openai.com`, `api.x.ai`, `api.anthropic.com` (only the ones you give keys for), HTTPS 443.
- **Check:** `curl -s -o /dev/null -m 10 -w '%{http_code}\n' https://api.openai.com/` (and likewise for the others you use). **Pass:** any number other
  than `000`. Prompts and answers travel on this path, so prefer Bedrock where you can.

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
- [ ] Every check in section 5 passed (5.1 the us-east-1 addresses, 5.2 the installer's computer, 5.3 in-region AWS services, 5.4-5.6 as they apply)
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
