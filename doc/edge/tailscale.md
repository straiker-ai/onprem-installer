# `edgeType: tailscale` — customer-side setup

This installer's `tailscale` edge type exposes Straiker's frontend/defend/ascend on your own,
customer-owned Tailscale tailnet, over your own domain, with a real browser-trusted certificate
(cert-manager + Let's Encrypt via Route53 DNS-01) — not a self-signed cert, and not a
`*.ts.net` hostname.

There's always a real Ingress controller (Caddy) terminating TLS in-cluster; Tailscale is used
purely as a private L3 network path to it (via the `tailscale.com/expose` Service annotation,
not an `Ingress`/`IngressClass`). This means the steps below — creating an OAuth client and
adding DNS records — happen entirely in **your own** Tailscale admin console. The installer
never creates or mints Tailscale credentials, and never touches a Straiker-owned tailnet.

## 1. Create a Tailscale account/tailnet

If you don't already have one: sign up at [tailscale.com](https://tailscale.com) and create a
tailnet. Any plan that supports the Kubernetes operator and OAuth clients works.

## 2. Define tag ownership in your ACL policy

An OAuth client can only be scoped to a tag once that tag has an owner defined in the tailnet's
ACL policy — do this before creating the OAuth client in the next step, or Tailscale will refuse
to let you scope it to `tag:k8s-operator`.

In the [Tailscale admin console](https://login.tailscale.com/admin/acls), add this to
`tagOwners` (merge it into your existing policy if you already have one):

```jsonc
{
  "tagOwners": {
    // Lets admins authenticate the operator's initial OAuth client.
    "tag:k8s-operator": ["autogroup:admin"],
    // Lets the operator itself create and manage tag:k8s proxies (the
    // per-Service proxy Pods the Tailscale Kubernetes operator creates).
    "tag:k8s": ["tag:k8s-operator", "autogroup:admin"],
  },
}
```

These are fixed tags this installer's OAuth-client prompt and the Tailscale Kubernetes
operator's own chart defaults both assume — don't rename them without also overriding the
operator's `operatorConfig.defaultTags`/`proxyConfig.defaultTags` to match.

## 3. Create an OAuth client

In the [Tailscale admin console](https://login.tailscale.com/admin/settings/oauth):

1. Go to **Settings → OAuth clients → Generate OAuth client**.
2. Scope it to `tag:k8s-operator` (this is what lets the Tailscale Kubernetes operator manage
   proxies on your tailnet). The operator's own default tags (`tag:k8s-operator` for itself,
   `tag:k8s` for the proxies it creates) already match this — no extra tag configuration needed
   on your end.
3. Copy the generated **Client ID** and **Client secret** — the installer will prompt for these
   (`--tailscale-oauth-client-id`/`--tailscale-oauth-client-secret`, or interactively).

## 4. Run the install

Pass `--edge-type tailscale`, your OAuth client ID/secret, a contact email for the Let's Encrypt
account (`--tailscale-cluster-issuer-email`), and your domain (`--custom-domain`, e.g.
`acmecorp.com` — its Route53 zone must already exist in the same AWS account this installer is
running against, since cert-manager's DNS-01 solver needs to write a challenge record there).

## 5. Point your domain at the assigned Tailscale IP

Once the install finishes, it prints either the Tailscale hostname assigned to the
`straiker-edge` Service, or points you at your Tailscale admin console's machine list to find it
(look for a machine named after the `straiker-edge` Service). Either way, find its IP.

In the [Tailscale admin console](https://login.tailscale.com/admin/dns), go to **DNS** and add
custom records mapping each hostname to that IP:

| Hostname | Target |
| --- | --- |
| `straiker.<your domain>` | the Tailscale IP |
| `straiker-defend.<your domain>` | the Tailscale IP |
| `straiker-ascend.<your domain>` | the Tailscale IP |

This is the simplest path and needs no extra AWS infrastructure — Tailscale answers these
records directly for every device on your tailnet.

**Alternative (Split DNS via an internal resolver):** if you'd rather manage DNS centrally
(e.g. you already run CoreDNS or a Route53 private hosted zone for other internal services),
you can instead go to **DNS → Nameservers → Add nameserver → Custom** and point it at that
resolver, restricted to your domain's search domain. This only makes sense if you're already
managing many such records elsewhere — for a handful of hostnames, the custom-record path above
is simpler and is what this installer is designed around.

## 6. Install Tailscale on end-user devices

Anyone who needs to reach the app installs the [Tailscale client](https://tailscale.com/download)
and signs in to join this tailnet. Once connected, the hostnames above resolve and work exactly
like any other website — same certificate, same browser padlock, no special configuration needed
per device beyond having Tailscale running.
