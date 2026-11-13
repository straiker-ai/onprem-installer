# AWS-native frontend for new on-prem customers (plan)

Goal: new customers hosted on AWS run the SaaS frontend (Frankfurt/Mumbai build) with the same AWS backends, created by the
installer in the customer's account. Omada stays on the Postgres/Dex adapter build (`onprem-v*` from `onprem/release`).

## What the SaaS frontend needs at runtime (from `apps/web`)

| Area | Env / resource | SaaS module that creates it | Installer today |
|---|---|---|---|
| Users, customers, apps, API keys, settings | `DYNAMODB_TABLE_NAME` (pk/sk, GSIs incl. `apiKey-index`), `DYNAMODB_GUARDRAILS_TABLE_NAME` | `infra/platform/cognito-environment-api/tf/dynamodb.tf` | missing |
| Login | `COGNITO_USER_POOL_ID`, `COGNITO_CLIENT_ID`, `COGNITO_EXTERNAL_PROVIDERS_CLIENT_ID`, `COGNITO_DOMAIN` | same module (`cognito.tf`, `domain.tf`) | have pool/client/domain (frontend client only; no external-providers client) |
| Login triggers (pre-auth, pre-sign-up, pre-token-generation, challenge x3) | Lambda from `lambda.zip` (foundation `dist/lambda`) | same module (`lambda.tf`) | deferred; needs Dynamo + lambda.zip |
| OpenSearch via Lambda | `AWS_OPENSEARCH_PROXY_FUNCTION_NAME` (`opensearch-proxy.handler`, nodejs22) | same module | missing (on-prem build uses a direct client) |
| Audit logs | `AUDIT_LOGS_STREAM` (Kinesis) | `infra/platform/audit-logs` | missing |
| Logos / uploads | `AWS_PUBLIC_ASSETS_BUCKET`, `AWS_ARTIFACTS_BUCKET` | `uploads.tf` (S3 + CDN) | missing |
| Email | `SES_REGION` | installer SES | have |
| AWS credentials | `AWS_ROLE_ARN` (SaaS: Vercel OIDC role) | `vercel` role in iam.tf | replace with EKS Pod Identity role |
| Other services | `PUBLIC_API_GATEWAY`, `TURNS_ENDPOINT`, `ARGUS_ENDPOINT`, `IRIS_CONTROL_PLANE_*`, `PRISM_BLOB_BASE_URL`, `INTERNAL_API_KEY*`, MCP OAuth secrets | cluster services / secrets | partly (ascend/defend charts) |

## Key finding

The login triggers have a **legacy DynamoDB-only path**: with no `platform_authz` base URL they never call Foundation
(variables.tf: "No base URL = legacy DynamoDB path only"). So Foundation is **not required** for login: Dynamo + `lambda.zip` is enough.

## Phases

1. **Data layer in the installer** (`terraform/aws/data`): DynamoDB tables (copy of `dynamodb.tf`), Lambda triggers + opensearch proxy
   (needs `lambda.zip` published to Straiker-owned bucket / copied by `artifacts-sync`), Kinesis audit stream, uploads bucket,
   external-providers Cognito client, Pod Identity policy for the frontend. Reuse the SaaS module logic, not a fork where possible.
2. **Frontend config**: chart env for the new vars; image = plain SaaS tag built for Kubernetes (the root `Dockerfile` / adapter-node), not the `onprem-*` adapter build.
3. **Seeding**: first customer, admin user (Dynamo + Cognito), straikerId, API keys; replaces `bootstrap.sql`.
4. **Frontend build**: ship SaaS tags as container images (ECR, ARM) alongside Vercel; confirm which SaaS-only pieces (Vercel OIDC, `$sso-origin`) need a Kubernetes path.
5. **Verify + docs**: installer verify checks (Dynamo reachable, triggers invoke, login end-to-end, audit record lands).

## Open questions (need answers before phase 1 is sized)

- Is `lambda.zip` (foundation `dist/lambda`) buildable/publishable for customers, and who owns that pipeline?
- Which of `PUBLIC_API_GATEWAY`, `TURNS_ENDPOINT`, `ARGUS_ENDPOINT`, `IRIS_CONTROL_PLANE_*` do the ascend/defend/iris on-prem charts already provide?
- Does the SaaS frontend run on Kubernetes today (root `Dockerfile` exists), or only on Vercel? Vercel-only pieces: OIDC token for AWS credentials, `$sso-origin`.
- Who seeds customers in SaaS (`infra/platform/seed-users`)? Reuse for on-prem first-admin creation.
