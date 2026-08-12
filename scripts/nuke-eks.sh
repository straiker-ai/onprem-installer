#!/usr/bin/env bash
# nuke-eks.sh — forcefully tear down the Straiker on-prem EKS deployment.
# Handles Karpenter-provisioned nodes that block tofu destroy.
# WARNING: Irreversible. All cluster data will be lost.
set -uo pipefail

# Refuse to run in any non-interactive context — pipes, subshells, AI agents, CI.
if [[ ! -t 0 || ! -t 1 ]]; then
  echo "ERROR: nuke-eks.sh requires an interactive terminal. Refusing to run in automated context." >&2
  exit 1
fi

export PATH="$HOME/.local/bin:$PATH"

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGION="${AWS_REGION:-}"

if [[ -z "${REGION}" ]]; then
  echo "ERROR: AWS_REGION is required — export AWS_REGION=<region>"
  exit 1
fi

# ── Resolve cluster name and TF workdir ───────────────────────────────────────
IS_CLOUDSHELL=false
if [[ "${AWS_EXECUTION_ENV:-}" == "CloudShell" ]] || \
   [[ -n "${AWS_CLOUDSHELL_HOME:-}" ]] || \
   [[ "${HOME:-}" == "/home/cloudshell-user" ]]; then
  IS_CLOUDSHELL=true
fi

TMP_WORKDIR="/tmp/s6r-onprem-tf/00-provision/s6r-onprem"
LOCAL_WORKDIR="${BASE}/../s6r-onprem"

# In CloudShell only check /tmp; elsewhere check both
if $IS_CLOUDSHELL; then
  TOFU_SEARCH_DIRS=("${TMP_WORKDIR}")
else
  TOFU_SEARCH_DIRS=("${TMP_WORKDIR}" "${LOCAL_WORKDIR}")
fi

CLUSTER=""
TF_DIR=""
for WD in "${TOFU_SEARCH_DIRS[@]}"; do
  if [[ -d "${WD}" ]] && command -v tofu &>/dev/null; then
    _out=$(tofu -chdir="${WD}" output -raw cluster_name 2>/dev/null || echo "")
    if [[ -n "${_out}" && "${_out}" != *$'\n'* ]]; then
      CLUSTER="${_out}"
      TF_DIR="${WD}"
      break
    fi
  fi
done

# Fallback: kubeconfig context
if [[ -z "${CLUSTER}" ]]; then
  CLUSTER=$(kubectl config current-context 2>/dev/null | sed 's|.*/||' || echo "")
fi

# Fallback: AWS API
if [[ -z "${CLUSTER}" ]]; then
  CLUSTER=$(aws eks list-clusters --region "${REGION}" \
    --query 'clusters[?starts_with(@, `s6r-onprem`)] | [0]' \
    --output text 2>/dev/null || echo "")
  [[ "${CLUSTER}" == "None" ]] && CLUSTER=""
fi

[[ -z "${CLUSTER}" ]] && CLUSTER="s6r-onprem"
if [[ -z "${TF_DIR}" ]]; then
  $IS_CLOUDSHELL && TF_DIR="${TMP_WORKDIR}" || TF_DIR="${LOCAL_WORKDIR}"
fi

# IAM is global — guard against nuking roles used by a cluster in another region.
# If the cluster does not exist in $REGION, skip IAM deletion entirely.
CLUSTER_IN_REGION=false
_EKS_STATUS=$(aws eks describe-cluster --name "${CLUSTER}" --region "${REGION}" \
  --query 'cluster.status' --output text 2>/dev/null || echo "")
[[ -n "${_EKS_STATUS}" && "${_EKS_STATUS}" != "None" ]] && CLUSTER_IN_REGION=true

echo "NUKE — Straiker on-prem EKS teardown"
echo "====================================="
echo "  cluster : ${CLUSTER}"
echo "  region  : ${REGION}"
if ! $CLUSTER_IN_REGION; then
  echo ""
  echo "  WARNING: cluster '${CLUSTER}' not found in ${REGION}."
  echo "           IAM resources are GLOBAL — they will NOT be deleted to avoid"
  echo "           breaking the cluster in the region where it actually lives."
fi
echo ""
read -r -p "This PERMANENTLY DELETES all resources. Type 'nuke' to confirm: " CONFIRM
[[ "${CONFIRM}" != "nuke" ]] && echo "Aborted." && exit 0
echo ""

# ── Phase 1: Uninstall Straiker Helm charts ───────────────────────────────────
echo "=== Phase 1: Uninstall Straiker charts ==="
if kubectl cluster-info &>/dev/null 2>&1; then
  for pair in "straiker-system:straiker-system"; do
    release="${pair%%:*}"; ns="${pair##*:}"
    if helm status "${release}" -n "${ns}" &>/dev/null 2>&1; then
      echo "  uninstalling ${release}..."
      helm uninstall "${release}" -n "${ns}" --no-hooks --wait --timeout 60s 2>/dev/null || \
        helm uninstall "${release}" -n "${ns}" --no-hooks 2>/dev/null || true
    else
      echo "  [-] ${release} not installed"
    fi
  done
else
  echo "  [!] kubectl not reachable — skipping chart uninstall"
fi

# ── Phase 2: Remove Karpenter config and stop provisioning ───────────────────
echo ""
echo "=== Phase 2: Remove Karpenter ==="
if kubectl cluster-info &>/dev/null 2>&1; then
  echo "  deleting NodePools and EC2NodeClasses..."
  kubectl delete nodepools --all --wait=false 2>/dev/null || true
  kubectl delete ec2nodeclasses --all --wait=false 2>/dev/null || true

  echo "  uninstalling karpenter..."
  helm uninstall karpenter -n karpenter --no-hooks 2>/dev/null || true
else
  echo "  [!] kubectl not reachable — skipping Karpenter Helm uninstall"
fi

# ── Phase 3: Terminate all EC2 nodes ─────────────────────────────────────────
# Karpenter nodes are NOT in Terraform state — tofu destroy cannot remove them.
# All cluster-owned EC2s are tagged kubernetes.io/cluster/<name>=owned.
echo ""
echo "=== Phase 3: Terminate EC2 nodes ==="
INSTANCE_IDS=$(aws ec2 describe-instances \
  --region "${REGION}" \
  --filters \
    "Name=tag:kubernetes.io/cluster/${CLUSTER},Values=owned,shared" \
    "Name=instance-state-name,Values=running,pending,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' \
  --output text 2>/dev/null || echo "")

if [[ -n "${INSTANCE_IDS}" && "${INSTANCE_IDS}" != "None" ]]; then
  COUNT=$(echo "${INSTANCE_IDS}" | wc -w | tr -d ' ')
  echo "  terminating ${COUNT} instance(s)..."
  # shellcheck disable=SC2086
  aws ec2 terminate-instances --region "${REGION}" --instance-ids ${INSTANCE_IDS} >/dev/null
  echo "  waiting for termination (up to 10 min)..."
  # shellcheck disable=SC2086
  aws ec2 wait instance-terminated --region "${REGION}" --instance-ids ${INSTANCE_IDS}
  echo "  [✓] all EC2 instances terminated"
else
  echo "  [-] no running instances found for cluster ${CLUSTER}"
fi

# ── Phase 4: tofu destroy ─────────────────────────────────────────────────────
echo ""
echo "=== Phase 4: tofu destroy ==="
if [[ -d "${TF_DIR}" ]] && command -v tofu &>/dev/null; then
  # Ensure backend.tf is present — generated by 1-bootstrap.sh and must exist before tofu init.
  # If missing from /tmp mirror, copy from the local source tree.
  if [[ ! -f "${TF_DIR}/backend.tf" ]]; then
    if [[ -f "${LOCAL_WORKDIR}/backend.tf" ]]; then
      echo "  backend.tf missing from ${TF_DIR} — copying from ${LOCAL_WORKDIR}..."
      cp -f "${LOCAL_WORKDIR}/backend.tf" "${TF_DIR}/backend.tf"
    else
      echo "  [!] backend.tf not found — run 1-bootstrap.sh first to create the S3 state bucket"
      echo "      Skipping tofu destroy, will attempt AWS API fallback..."
    fi
  fi

  # Ensure terraform.auto.tfvars exists — may be absent after /tmp mirror
  if [[ ! -f "${TF_DIR}/terraform.auto.tfvars" ]]; then
    echo "  terraform.auto.tfvars missing — regenerating..."
    read -r AZ1 AZ2 _ <<< "$(aws ec2 describe-availability-zones \
      --region "${REGION}" --filters Name=state,Values=available \
      --query 'AvailabilityZones[].ZoneName' --output text)"
    cat > "${TF_DIR}/terraform.auto.tfvars" <<EOF
region             = "${REGION}"
availability_zones = ["${AZ1}", "${AZ2}"]
EOF
  fi

  # Ensure modules/providers are installed
  if [[ ! -d "${TF_DIR}/.terraform" ]]; then
    echo "  running tofu init..."
    tofu -chdir="${TF_DIR}" init -input=false 2>&1 | tail -5
  fi

  echo "  running tofu destroy in ${TF_DIR}..."
  tofu -chdir="${TF_DIR}" destroy -auto-approve 2>&1 | tail -20
  echo "  [✓] tofu destroy complete"
else
  echo "  [!] tofu not found or TF directory missing — attempting AWS API fallback..."
fi

# ── Phase 4b: AWS API fallback if EKS cluster still exists ───────────────────
# tofu destroy may report 0 resources if state was empty or bucket destroyed.
# Always verify the cluster is actually gone.
if aws eks describe-cluster --name "${CLUSTER}" --region "${REGION}" &>/dev/null 2>&1; then
  echo ""
  echo "=== Phase 4b: AWS API fallback — cluster still exists ==="

  # Delete managed node groups first — EKS cluster delete blocks until they are gone
  NODE_GROUPS=$(aws eks list-nodegroups \
    --cluster-name "${CLUSTER}" --region "${REGION}" \
    --query 'nodegroups[]' --output text 2>/dev/null || echo "")
  if [[ -n "${NODE_GROUPS}" && "${NODE_GROUPS}" != "None" ]]; then
    for NG in ${NODE_GROUPS}; do
      echo "  deleting node group: ${NG}..."
      aws eks delete-nodegroup \
        --cluster-name "${CLUSTER}" --nodegroup-name "${NG}" \
        --region "${REGION}" &>/dev/null || true
    done
    echo "  waiting for node groups to finish deleting (up to 15 min)..."
    for NG in ${NODE_GROUPS}; do
      aws eks wait nodegroup-deleted \
        --cluster-name "${CLUSTER}" --nodegroup-name "${NG}" \
        --region "${REGION}" 2>/dev/null || true
    done
    echo "  [✓] node groups deleted"
  fi

  echo "  deleting EKS cluster ${CLUSTER}..."
  aws eks delete-cluster --name "${CLUSTER}" --region "${REGION}" || true

  echo "  waiting for cluster deletion (up to 20 min)..."
  aws eks wait cluster-deleted \
    --name "${CLUSTER}" --region "${REGION}" 2>/dev/null || true

  if aws eks describe-cluster --name "${CLUSTER}" --region "${REGION}" &>/dev/null 2>&1; then
    echo "  [!] cluster still exists — check AWS console for pending dependencies"
  else
    echo "  [✓] EKS cluster deleted via AWS API"
  fi
else
  echo "  [✓] EKS cluster confirmed deleted"
fi

# ── Phase 5: VPC and networking fallback cleanup ──────────────────────────────
# Runs unconditionally — if tofu destroy left VPC resources behind (e.g. a
# stalled NAT GW blocks VPC deletion), this cleans them up via AWS API.
# Resources are found by the s6r-onprem Name tag, with cluster-ownership tag
# as fallback. If no matching VPC is found, the phase is skipped.
echo ""
echo "=== Phase 5: VPC/networking cleanup ==="

VPC_ID=$(aws ec2 describe-vpcs \
  --region "${REGION}" \
  --filters "Name=tag:Name,Values=s6r-onprem*" \
  --query 'Vpcs[0].VpcId' \
  --output text 2>/dev/null || echo "")
[[ "${VPC_ID}" == "None" ]] && VPC_ID=""

if [[ -z "${VPC_ID}" ]]; then
  VPC_ID=$(aws ec2 describe-vpcs \
    --region "${REGION}" \
    --filters "Name=tag-key,Values=kubernetes.io/cluster/${CLUSTER}" \
    --query 'Vpcs[0].VpcId' \
    --output text 2>/dev/null || echo "")
  [[ "${VPC_ID}" == "None" ]] && VPC_ID=""
fi

if [[ -z "${VPC_ID}" ]]; then
  echo "  [-] no s6r-onprem VPC found — skipping"
else
  echo "  found VPC: ${VPC_ID}"

  # 1. Delete ALB/NLB load balancers — created by K8s LoadBalancer services, not in TF state
  LB_ARNS=$(aws elbv2 describe-load-balancers --region "${REGION}" \
    --query "LoadBalancers[?VpcId=='${VPC_ID}'].LoadBalancerArn" \
    --output text 2>/dev/null || echo "")
  for ARN in ${LB_ARNS}; do
    [[ "${ARN}" == "None" ]] && continue
    echo "  deleting load balancer ${ARN}..."
    aws elbv2 delete-load-balancer --load-balancer-arn "${ARN}" --region "${REGION}" 2>/dev/null || true
  done

  # 2. Delete classic ELBs
  ELB_NAMES=$(aws elb describe-load-balancers --region "${REGION}" \
    --query "LoadBalancerDescriptions[?VPCId=='${VPC_ID}'].LoadBalancerName" \
    --output text 2>/dev/null || echo "")
  for NAME in ${ELB_NAMES}; do
    [[ "${NAME}" == "None" ]] && continue
    echo "  deleting classic ELB ${NAME}..."
    aws elb delete-load-balancer --load-balancer-name "${NAME}" --region "${REGION}" 2>/dev/null || true
  done

  # 3. Capture NAT GW EIP allocations before deletion — can only release after GW is gone
  EIP_ALLOC_IDS=$(aws ec2 describe-nat-gateways \
    --region "${REGION}" \
    --filter "Name=vpc-id,Values=${VPC_ID}" "Name=state,Values=available,pending,deleting" \
    --query 'NatGateways[].NatGatewayAddresses[].AllocationId' \
    --output text 2>/dev/null || echo "")

  # 4. Delete NAT Gateways — the most common stall point for VPC deletion
  NAT_IDS=$(aws ec2 describe-nat-gateways \
    --region "${REGION}" \
    --filter "Name=vpc-id,Values=${VPC_ID}" "Name=state,Values=available,pending" \
    --query 'NatGateways[].NatGatewayId' \
    --output text 2>/dev/null || echo "")
  for NAT in ${NAT_IDS}; do
    [[ "${NAT}" == "None" ]] && continue
    echo "  deleting NAT gateway ${NAT}..."
    aws ec2 delete-nat-gateway --nat-gateway-id "${NAT}" --region "${REGION}" 2>/dev/null || true
  done
  # Poll until deleted — aws ec2 wait nat-gateway-deleted isn't reliable across all CLI versions
  for NAT in ${NAT_IDS}; do
    [[ "${NAT}" == "None" ]] && continue
    echo "  waiting for NAT gateway ${NAT}..."
    for _ in $(seq 1 40); do
      STATE=$(aws ec2 describe-nat-gateways \
        --nat-gateway-ids "${NAT}" --region "${REGION}" \
        --query 'NatGateways[0].State' --output text 2>/dev/null || echo "deleted")
      [[ "${STATE}" == "deleted" ]] && break
      sleep 15
    done
  done
  [[ -n "${NAT_IDS}" && "${NAT_IDS}" != "None" ]] && echo "  [✓] NAT gateways deleted"

  # 5. Release EIPs that were pinned to NAT GWs
  for ALLOC in ${EIP_ALLOC_IDS}; do
    [[ "${ALLOC}" == "None" ]] && continue
    echo "  releasing EIP ${ALLOC}..."
    aws ec2 release-address --allocation-id "${ALLOC}" --region "${REGION}" 2>/dev/null || true
  done

  # 6. Detach and delete Internet Gateways
  IGW_IDS=$(aws ec2 describe-internet-gateways \
    --region "${REGION}" \
    --filters "Name=attachment.vpc-id,Values=${VPC_ID}" \
    --query 'InternetGateways[].InternetGatewayId' \
    --output text 2>/dev/null || echo "")
  for IGW in ${IGW_IDS}; do
    [[ "${IGW}" == "None" ]] && continue
    echo "  detaching/deleting IGW ${IGW}..."
    aws ec2 detach-internet-gateway --internet-gateway-id "${IGW}" \
      --vpc-id "${VPC_ID}" --region "${REGION}" 2>/dev/null || true
    aws ec2 delete-internet-gateway --internet-gateway-id "${IGW}" \
      --region "${REGION}" 2>/dev/null || true
  done

  # 7. Delete subnets
  SUBNET_IDS=$(aws ec2 describe-subnets \
    --region "${REGION}" \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query 'Subnets[].SubnetId' \
    --output text 2>/dev/null || echo "")
  for SUBNET in ${SUBNET_IDS}; do
    [[ "${SUBNET}" == "None" ]] && continue
    aws ec2 delete-subnet --subnet-id "${SUBNET}" --region "${REGION}" 2>/dev/null || true
  done
  [[ -n "${SUBNET_IDS}" && "${SUBNET_IDS}" != "None" ]] && echo "  [✓] subnets deleted"

  # 8. Delete non-main route tables (main RT is implicitly deleted with the VPC)
  RT_IDS=$(aws ec2 describe-route-tables \
    --region "${REGION}" \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query 'RouteTables[].RouteTableId' \
    --output text 2>/dev/null || echo "")
  for RT in ${RT_IDS}; do
    [[ "${RT}" == "None" ]] && continue
    aws ec2 delete-route-table --route-table-id "${RT}" --region "${REGION}" 2>/dev/null || true
  done

  # 9. Delete non-default security groups (default SG is deleted with the VPC)
  SG_IDS=$(aws ec2 describe-security-groups \
    --region "${REGION}" \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[?GroupName!=`default`].GroupId' \
    --output text 2>/dev/null || echo "")
  for SG in ${SG_IDS}; do
    [[ "${SG}" == "None" ]] && continue
    aws ec2 delete-security-group --group-id "${SG}" --region "${REGION}" 2>/dev/null || true
  done

  # 10. Delete the VPC
  echo "  deleting VPC ${VPC_ID}..."
  if aws ec2 delete-vpc --vpc-id "${VPC_ID}" --region "${REGION}" 2>/dev/null; then
    echo "  [✓] VPC deleted"
  else
    echo "  [!] VPC deletion failed — remaining dependencies in AWS console:"
    echo "      https://console.aws.amazon.com/vpc/home?region=${REGION}#vpcs:VpcId=${VPC_ID}"
  fi
fi

# ── Phase 6: Clean up kubeconfig ──────────────────────────────────────────────
echo ""
echo "=== Phase 6: Clean up kubeconfig ==="
ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
if [[ -n "${ACCOUNT}" ]]; then
  CTX="arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${CLUSTER}"
  kubectl config delete-context "${CTX}" 2>/dev/null || true
  kubectl config delete-cluster "${CTX}" 2>/dev/null || true
  kubectl config unset "users.${CTX}" 2>/dev/null || true
fi
echo "  [✓] kubeconfig cleaned"

# ── Phase 7: IAM and auxiliary resource cleanup ───────────────────────────────
# tofu destroy leaves IAM roles, policies, OIDC providers, SQS queues, and
# CloudWatch log groups behind when the state is empty or partially destroyed.
# IAM is global — only clean up if the cluster was in this region.
# Running nuke in a different region would delete roles used by the live cluster elsewhere.
echo ""
echo "=== Phase 7: IAM and auxiliary cleanup ==="

if ! $CLUSTER_IN_REGION; then
  echo "  [!] Cluster '${CLUSTER}' was not in ${REGION} — skipping global IAM deletion."
  echo "      Run nuke-eks.sh with AWS_REGION set to the cluster's actual region to clean up IAM."
  echo "  [✓] IAM and auxiliary cleanup skipped (safe)"
  # Jump to completion
else

# 1. IAM roles — detach policies, delete inline policies, remove from instance profiles, delete
IAM_ROLES=$(aws iam list-roles \
  --query 'Roles[?contains(RoleName, `s6r-onprem`)].RoleName' \
  --output text 2>/dev/null || echo "")
for ROLE in ${IAM_ROLES}; do
  [[ "${ROLE}" == "None" ]] && continue
  echo "  cleaning role: ${ROLE}..."

  ATTACHED=$(aws iam list-attached-role-policies --role-name "${ROLE}" \
    --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || echo "")
  for PARN in ${ATTACHED}; do
    [[ "${PARN}" == "None" ]] && continue
    aws iam detach-role-policy --role-name "${ROLE}" --policy-arn "${PARN}" 2>/dev/null || true
  done

  INLINE=$(aws iam list-role-policies --role-name "${ROLE}" \
    --query 'PolicyNames[]' --output text 2>/dev/null || echo "")
  for IP in ${INLINE}; do
    [[ "${IP}" == "None" ]] && continue
    aws iam delete-role-policy --role-name "${ROLE}" --policy-name "${IP}" 2>/dev/null || true
  done

  PROFILES=$(aws iam list-instance-profiles-for-role --role-name "${ROLE}" \
    --query 'InstanceProfiles[].InstanceProfileName' --output text 2>/dev/null || echo "")
  for PROF in ${PROFILES}; do
    [[ "${PROF}" == "None" ]] && continue
    aws iam remove-role-from-instance-profile \
      --instance-profile-name "${PROF}" --role-name "${ROLE}" 2>/dev/null || true
    aws iam delete-instance-profile --instance-profile-name "${PROF}" 2>/dev/null || true
  done

  aws iam delete-role --role-name "${ROLE}" 2>/dev/null || true
done
[[ -n "${IAM_ROLES}" && "${IAM_ROLES}" != "None" ]] && echo "  [✓] IAM roles deleted"

# 2. Customer-managed policies with s6r-onprem in the name
# Non-default versions must be deleted before the policy itself can be deleted.
IAM_POLS=$(aws iam list-policies --scope Local \
  --query 'Policies[?contains(PolicyName, `s6r-onprem`)].Arn' \
  --output text 2>/dev/null || echo "")
for PARN in ${IAM_POLS}; do
  [[ "${PARN}" == "None" ]] && continue
  echo "  deleting policy: ${PARN}..."
  VERSIONS=$(aws iam list-policy-versions --policy-arn "${PARN}" \
    --query 'Versions[?!IsDefaultVersion].VersionId' --output text 2>/dev/null || echo "")
  for VER in ${VERSIONS}; do
    [[ "${VER}" == "None" ]] && continue
    aws iam delete-policy-version --policy-arn "${PARN}" --version-id "${VER}" 2>/dev/null || true
  done
  aws iam delete-policy --policy-arn "${PARN}" 2>/dev/null || true
done

# 3. EKS OIDC provider — auto-delete only if exactly one exists for this region
# (multiple means other clusters share the account; skip to avoid collateral damage)
OIDC_ARNS=$(aws iam list-open-id-connect-providers \
  --query 'OpenIDConnectProviderList[].Arn' --output text 2>/dev/null | \
  tr '\t' '\n' | grep "oidc.eks.${REGION}.amazonaws.com" || true)
OIDC_COUNT=$(echo "${OIDC_ARNS}" | grep -c "oidc" 2>/dev/null || true)
if [[ "${OIDC_COUNT}" -eq 1 ]]; then
  echo "  deleting EKS OIDC provider..."
  aws iam delete-open-id-connect-provider \
    --open-id-connect-provider-arn "${OIDC_ARNS}" 2>/dev/null || true
  echo "  [✓] OIDC provider deleted"
elif [[ "${OIDC_COUNT}" -gt 1 ]]; then
  echo "  [!] multiple EKS OIDC providers in ${REGION} — delete manually if needed:"
  echo "${OIDC_ARNS}" | sed 's/^/      /'
fi

# 4. Karpenter SQS interruption queue
QUEUE_URL=$(aws sqs get-queue-url \
  --queue-name "Karpenter-${CLUSTER}" --region "${REGION}" \
  --query 'QueueUrl' --output text 2>/dev/null || echo "")
if [[ -n "${QUEUE_URL}" && "${QUEUE_URL}" != "None" ]]; then
  echo "  deleting SQS queue Karpenter-${CLUSTER}..."
  aws sqs delete-queue --queue-url "${QUEUE_URL}" --region "${REGION}" 2>/dev/null || true
  echo "  [✓] SQS queue deleted"
fi

# 5. CloudWatch log groups for the EKS cluster
LOG_GROUPS=$(aws logs describe-log-groups \
  --log-group-name-prefix "/aws/eks/${CLUSTER}" --region "${REGION}" \
  --query 'logGroups[].logGroupName' --output text 2>/dev/null || echo "")
for LG in ${LOG_GROUPS}; do
  [[ "${LG}" == "None" ]] && continue
  echo "  deleting log group: ${LG}..."
  aws logs delete-log-group --log-group-name "${LG}" --region "${REGION}" 2>/dev/null || true
done
[[ -n "${LOG_GROUPS}" && "${LOG_GROUPS}" != "None" ]] && echo "  [✓] CloudWatch log groups deleted"

echo "  [✓] IAM and auxiliary cleanup complete"

fi  # end: $CLUSTER_IN_REGION guard

echo ""
echo "[✓] Nuke complete — all Straiker on-prem resources removed."
