# onprem-installer
Public tools and charts for onprem install

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/straiker-ai/onprem-installer/dist/install.sh | bash -s -- --install-eks --aws-region us-east-1
```

Already have a Kubernetes cluster? Drop `--install-eks --aws-region ...` and it just installs the `straiker-system` chart:

```bash
curl -fsSL https://raw.githubusercontent.com/straiker-ai/onprem-installer/dist/install.sh | bash
```

That one-liner is a small launcher: it downloads and caches a versioned installer bundle (the phased
installer script + the Terraform modules under `terraform/`), then runs it. The release workflow
rebuilds and publishes that bundle, and the launcher itself, to the `dist` branch on every push
to `main` — see `scripts/launch-straiker.sh`, `scripts/install-straiker.sh`, and
`.github/workflows/release.yml`.

Run `curl -fsSL .../dist/install.sh | bash -s -- --help` for the full list of options (phase
selection, `--status`, values files, chart version pinning, etc).

### Bring your own VPC

`--install-eks` normally provisions its own VPC. If your AWS account's Organizations SCP denies
`ec2:CreateVpc` (or you just want EKS attached to an existing network), pass `--vpc-id` together
with `--private-subnet-ids` and `--public-subnet-ids` (all three required together):

```bash
curl -fsSL https://raw.githubusercontent.com/straiker-ai/onprem-installer/dist/install.sh | bash -s -- \
  --install-eks --aws-region us-east-1 \
  --vpc-id vpc-0123456789abcdef0 \
  --private-subnet-ids subnet-0aaa...,subnet-0bbb... \
  --public-subnet-ids subnet-0ccc...,subnet-0ddd...
```

IAM needed instead of `ec2:CreateVpc`/`CreateSubnet`/`CreateNatGateway`/etc.: `ec2:DescribeVpcs`,
`ec2:DescribeSubnets`, `ec2:DescribeRouteTables`, `ec2:CreateTags`, `ec2:DeleteTags` (the installer
tags your subnets `kubernetes.io/role/*-elb` and `karpenter.sh/discovery`, which the AWS Load
Balancer Controller and Karpenter both require to discover them).

This mode does **not** create a NAT gateway — your supplied private subnets must already have their
own outbound internet routing. Like `--cloud-provider`/`--provision-strategy`, this is first-run-only:
once set, it's permanent for the install recorded in `~/.straiker/install.json`.

## Disable the default admin login

Every install ships with a bootstrap admin login (`admin@<appDomain>`) so you can log in on day
one — but it uses the same password hash on every onprem install, so it shouldn't stay enabled
indefinitely. Once you've onboarded a real admin (a local account created through the UI, or your
own configured OIDC IdP), disable it:

```bash
curl -fsSL https://raw.githubusercontent.com/straiker-ai/onprem-installer/dist/install.sh | bash -s -- --disable-builtin-admin
```

This is a standalone action, not a phase — it doesn't need `--phase`/`--rerun-phase`. It prompts
for confirmation (type `disable`) unless you pass `--yes`, and only removes that one static login;
dex's own dynamically-managed local logins and any configured external IdP are unaffected. To
re-enable it later, run a normal install with `--values` setting
`straiker-frontend.dex.staticAdminEnabled: true`.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/straiker-ai/onprem-installer/dist/uninstall.sh | bash
```

Uninstalls the Helm release. It reads `~/.straiker/install.json` (written by the install) to run the
same bundle version that was installed and to know whether this installer provisioned EKS. Add
`--destroy-eks` to also tear down the EKS cluster and Terraform state bucket it created — this is
interactive by default (it asks you to type the cluster name to confirm) and refuses to run if
install state doesn't show this installer provisioned EKS, or if there's no bundle version/state to
go on. Pass `--yes` to skip the confirmation for non-interactive use, and `--aws-region`/
`--cluster-name`/`--tf-prefix` to override values read from state.

`scripts/nuke-eks.sh` is a separate, manual escape hatch for messier teardowns (state lost/out of
sync, VPC stuck on a stray load balancer or NAT gateway, IAM leftovers) — run it directly if
`--destroy-eks` doesn't fully clean up. It's included in the installer bundle, so after any
install/uninstall run it's already on disk at `~/.straiker/installer/<version>/scripts/nuke-eks.sh`;
`uninstall-straiker.sh` points at that exact path in its own warnings when it detects this. Since it
refuses to run non-interactively (no `curl | bash`), fetch it directly if you don't have a bundle yet:

```bash
curl -fsSL https://raw.githubusercontent.com/straiker-ai/onprem-installer/main/scripts/nuke-eks.sh -o nuke-eks.sh
chmod +x nuke-eks.sh
AWS_REGION=us-east-1 ./nuke-eks.sh
```
