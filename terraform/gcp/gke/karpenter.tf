# Karpenter on GKE has no native cluster add-on (unlike what
# charts/straiker-system's karpenter-*-gke.yaml fail-message URL used to
# imply — that Google Cloud doc page doesn't exist, now fixed). The real,
# actively-maintained GKE provider is the community project
# cloudpilot-ai/karpenter-provider-gcp, self-installed via its own Helm
# repo the same way we self-install upstream Karpenter's OCI chart on EKS
# (see install-straiker.sh's phase_karpenter) — Terraform here only sets up
# the IAM/Workload Identity prerequisites that controller needs, not the
# chart itself.
#
# IAM permissions and namespace/ServiceAccount names below are taken
# directly from the project's own installation guide and canonical
# permission list (deploy/iam/karpenter-controller-role.yaml in that repo),
# not guessed — verified 2026-08 against
# https://github.com/cloudpilot-ai/karpenter-provider-gcp/blob/main/docs/getting-started/installation.md.
resource "google_service_account" "karpenter" {
  project      = var.project_id
  account_id   = "${var.cluster_name}-karpenter"
  display_name = "Karpenter controller SA for ${var.cluster_name}"

  depends_on = [google_project_service.required]
}

# Mirrors deploy/iam/karpenter-controller-role.yaml verbatim — a minimal
# custom role, not a broad predefined one, since the project maintains this
# list as its documented source of truth.
resource "google_project_iam_custom_role" "karpenter_controller" {
  project     = var.project_id
  role_id     = "karpenter_controller"
  title       = "Karpenter Controller"
  description = "Minimal IAM role for the karpenter-provider-gcp controller service account."
  stage       = "GA"
  permissions = [
    "compute.instances.create",
    "compute.instances.delete",
    "compute.instances.get",
    "compute.instances.list",
    "compute.instances.setLabels",
    "compute.instances.setMetadata",
    "compute.instances.setServiceAccount",
    "compute.instances.setTags",
    "compute.disks.create",
    "compute.images.get",
    "compute.images.list",
    "compute.instanceGroupManagers.get",
    "compute.machineTypes.list",
    "compute.networks.get",
    "compute.projects.get",
    "compute.instanceTemplates.get",
    "compute.instanceTemplates.list",
    "compute.regions.get",
    "compute.subnetworks.get",
    "compute.subnetworks.use",
    "compute.subnetworks.useExternalIp",
    "compute.zones.list",
    "compute.zoneOperations.get",
    "container.clusters.get",
    "container.clusters.list",
    "container.clusters.update",
  ]
}

resource "google_project_iam_member" "karpenter_controller" {
  project = var.project_id
  role    = google_project_iam_custom_role.karpenter_controller.id
  member  = "serviceAccount:${google_service_account.karpenter.email}"
}

# Dedicated SA for Karpenter-launched application nodes — deliberately
# separate from gke.tf's fixed "system" pool SA (matches the install guide's
# own separation: Karpenter's dynamically-scaled fleet doesn't need the same
# identity as the small always-on controller/addons pool). Wired in as the
# cluster-wide default via phase_karpenter's
# controller.settings.defaultNodepoolServiceAccount Helm flag, so no
# per-GCENodeClass chart change is needed.
resource "google_service_account" "karpenter_node" {
  project      = var.project_id
  account_id   = "${var.cluster_name}-karpenter-node"
  display_name = "Karpenter-launched node SA for ${var.cluster_name}"

  depends_on = [google_project_service.required]
}

# Bundles logging.logWriter, monitoring.metricWriter, monitoring.viewer,
# stackdriver.resourceMetadata.writer — the GKE-documented minimum for any
# node SA.
resource "google_project_iam_member" "karpenter_node" {
  project = var.project_id
  role    = "roles/container.nodeServiceAccount"
  member  = "serviceAccount:${google_service_account.karpenter_node.email}"
}

# Lets nodes pull the mirrored images from the customer's own Artifact
# Registry — same reasoning as gke.tf's system-pool SA.
resource "google_project_iam_member" "karpenter_node_artifact_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.karpenter_node.email}"
}

# Lets the controller attach the node SA to instances it creates — scoped to
# each SA Karpenter may attach, per the install guide's own warning.
resource "google_service_account_iam_member" "karpenter_use_node_sa" {
  service_account_id = google_service_account.karpenter_node.name
  role                = "roles/iam.serviceAccountUser"
  member              = "serviceAccount:${google_service_account.karpenter.email}"
}

# Binds the controller GCP SA to the K8s ServiceAccount the Helm chart
# creates — namespace "karpenter-system", name "karpenter", both fixed by
# the chart's own defaults (not customer-configurable without also changing
# phase_karpenter's --namespace flag).
resource "google_service_account_iam_member" "karpenter_workload_identity" {
  service_account_id = google_service_account.karpenter.name
  role                = "roles/iam.workloadIdentityUser"
  member              = "serviceAccount:${var.project_id}.svc.id.goog[karpenter-system/karpenter]"
}
