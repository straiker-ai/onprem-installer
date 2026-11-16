#!/usr/bin/env bash
# Read-only inventory of what an install left in an AWS account, by cluster name and Terraform prefix. Run it before a teardown
# (to see what will go) and after one (to prove nothing is left). It only calls Describe/List APIs and changes nothing.
#
#   scripts/list-cluster-resources.sh --cluster-name vb --tf-prefix vb --region us-west-2 --profile s6rstage [--zone-id Z...]
#
# Exit code: 0 = nothing found (clean), 1 = something is left, 2 = bad usage.
set -uo pipefail

CLUSTER=""
PREFIX=""
REGION="${AWS_REGION:-}"
PROFILE=""
ZONE_ID=""

usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster-name) CLUSTER="${2:-}"; shift 2 ;;
    --tf-prefix) PREFIX="${2:-}"; shift 2 ;;
    --region) REGION="${2:-}"; shift 2 ;;
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --zone-id) ZONE_ID="${2:-}"; shift 2 ;;
    -h | --help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done
[[ -n "${CLUSTER}" && -n "${REGION}" ]] || usage
PREFIX="${PREFIX:-${CLUSTER}}"
[[ -n "${PROFILE}" ]] && export AWS_PROFILE="${PROFILE}"
export AWS_REGION="${REGION}" AWS_DEFAULT_REGION="${REGION}" AWS_PAGER=""

FOUND=0
account="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" || { echo "AWS credentials do not work (profile '${PROFILE:-default}')." >&2; exit 2; }
echo "Account ${account}, region ${REGION}, cluster '${CLUSTER}', prefix '${PREFIX}'"
echo

# section <title> <command output (one item per line)>
section() {
  local title=$1 items=$2 n
  items="$(printf '%s\n' "${items}" | tr '\t' '\n' | sed '/^[[:space:]]*$/d;/^None$/d')"
  n=$(printf '%s' "${items}" | grep -c . || true)
  if [[ "${n}" -gt 0 ]]; then
    FOUND=1
    printf '%-30s %s\n' "${title}" "${n} found"
    printf '%s\n' "${items}" | sed 's/^/    /'
  else
    printf '%-30s none\n' "${title}"
  fi
}

section "EKS cluster" "$(aws eks list-clusters --query "clusters[?@=='${CLUSTER}']" --output text 2>/dev/null)"
section "EC2 instances (running)" "$(aws ec2 describe-instances --filters "Name=tag-key,Values=kubernetes.io/cluster/${CLUSTER}" \
  "Name=instance-state-name,Values=pending,running,stopping,stopped" --query 'Reservations[].Instances[].[InstanceId,InstanceType,Placement.AvailabilityZone]' --output text 2>/dev/null | tr '\t' ' ')"
section "Capacity-probe instances" "$(aws ec2 describe-instances --filters "Name=tag:straiker-capacity-probe,Values=${CLUSTER}" \
  "Name=instance-state-name,Values=pending,running,stopping,stopped" --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null)"
section "Load balancers" "$(aws resourcegroupstaggingapi get-resources --resource-type-filters elasticloadbalancing:loadbalancer \
  --tag-filters "Key=elbv2.k8s.aws/cluster,Values=${CLUSTER}" --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null)"
vpcs="$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${CLUSTER}*" --query 'Vpcs[].VpcId' --output text 2>/dev/null)"
section "VPCs (by Name tag)" "${vpcs}"
nat=""
for v in ${vpcs}; do nat+="$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=${v}" "Name=state,Values=available,pending,deleting" --query 'NatGateways[].NatGatewayId' --output text 2>/dev/null) "; done
section "NAT gateways" "${nat}"
section "Aurora clusters" "$(aws rds describe-db-clusters --query "DBClusters[?starts_with(DBClusterIdentifier, '${CLUSTER}-')].DBClusterIdentifier" --output text 2>/dev/null)"
section "Aurora snapshots (manual)" "$(aws rds describe-db-cluster-snapshots --snapshot-type manual --query "DBClusterSnapshots[?starts_with(DBClusterSnapshotIdentifier, '${CLUSTER}-')].DBClusterSnapshotIdentifier" --output text 2>/dev/null)"
section "MSK clusters" "$(aws kafka list-clusters-v2 --query "ClusterInfoList[?starts_with(ClusterName, '${CLUSTER}-')].ClusterName" --output text 2>/dev/null)"
section "OpenSearch domains" "$(aws opensearch list-domain-names --query "DomainNames[?starts_with(DomainName, '${CLUSTER}-')].DomainName" --output text 2>/dev/null)"
section "ElastiCache" "$(aws elasticache describe-serverless-caches --query "ServerlessCaches[?starts_with(ServerlessCacheName, '${CLUSTER}-')].ServerlessCacheName" --output text 2>/dev/null) $(aws elasticache describe-replication-groups --query "ReplicationGroups[?starts_with(ReplicationGroupId, '${CLUSTER}-')].ReplicationGroupId" --output text 2>/dev/null)"
section "EFS file systems" "$(aws efs describe-file-systems --query "FileSystems[?starts_with(Name, '${CLUSTER}')].FileSystemId" --output text 2>/dev/null)"
section "DynamoDB tables" "$(aws dynamodb list-tables --query "TableNames[?starts_with(@, '${CLUSTER}-')]" --output text 2>/dev/null)"
section "Cognito user pools" "$(aws cognito-idp list-user-pools --max-results 60 --query "UserPools[?starts_with(Name, '${CLUSTER}-')].[Id,Name]" --output text 2>/dev/null | tr '\t' ' ')"
section "SES identities (all)" "$(aws sesv2 list-email-identities --query 'EmailIdentities[].IdentityName' --output text 2>/dev/null)"
section "Secrets (incl. scheduled)" "$(aws secretsmanager list-secrets --include-planned-deletion --query "SecretList[?starts_with(Name, '${CLUSTER}/')].[Name,DeletedDate]" --output text 2>/dev/null | tr '\t' ' ')"
section "KMS aliases" "$(aws kms list-aliases --query "Aliases[?starts_with(AliasName, 'alias/${CLUSTER}')].AliasName" --output text 2>/dev/null)"
section "S3 buckets" "$(aws s3api list-buckets --query "Buckets[?starts_with(Name, '${CLUSTER}-') || starts_with(Name, '${PREFIX}-')].Name" --output text 2>/dev/null)"
section "ECR repositories" "$(aws ecr describe-repositories --query "repositories[?starts_with(repositoryName, '${CLUSTER}/') || starts_with(repositoryName, '${PREFIX}/')].repositoryName" --output text 2>/dev/null)"
section "IAM roles" "$(aws iam list-roles --query "Roles[?starts_with(RoleName, '${PREFIX}-') || starts_with(RoleName, '${CLUSTER}-')].RoleName" --output text 2>/dev/null)"
section "WAF web ACLs" "$(aws wafv2 list-web-acls --scope REGIONAL --query "WebACLs[?starts_with(Name, '${CLUSTER}-')].Name" --output text 2>/dev/null)"
section "ACM certificates" "$(aws acm list-certificates --query 'CertificateSummaryList[].DomainName' --output text 2>/dev/null)"
logs=""
for lp in "/aws/containerinsights/${CLUSTER}" "/aws/eks/${CLUSTER}" "aws-waf-logs-${CLUSTER}" "/aws/vendedlogs/${CLUSTER}"; do
  logs+="$(aws logs describe-log-groups --log-group-name-prefix "${lp}" --query 'logGroups[].logGroupName' --output text 2>/dev/null) "
done
section "CloudWatch log groups" "${logs}"
section "SNS topics" "$(aws sns list-topics --query "Topics[?contains(TopicArn, '${CLUSTER}')].TopicArn" --output text 2>/dev/null)"
if [[ -n "${ZONE_ID}" ]]; then
  section "Route53 records (not NS/SOA)" "$(aws route53 list-resource-record-sets --hosted-zone-id "${ZONE_ID}" \
    --query "ResourceRecordSets[?Type!='NS' && Type!='SOA'].[Type,Name]" --output text 2>/dev/null | tr '\t' ' ')"
fi

echo
echo "Left alone on purpose: account-wide service-linked roles, the Route53 hosted zone itself, SES identities and ACM"
echo "certificates of other installs (the two lists above are NOT filtered by cluster: check the names), and anything not"
echo "named with this cluster or prefix."
if [[ ${FOUND} -eq 0 ]]; then echo "Result: clean."; exit 0; fi
echo "Result: resources are left."
exit 1
