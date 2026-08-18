# Dedicated minimal-scope SA for node VMs — the GCE default service account
# carries broad project-editor-equivalent permissions, which is exactly the
# kind of over-broad grant AWS's node IAM role (scoped to just what
# eks_managed_node_groups needs) avoids. artifactregistry.reader lets nodes
# pull the mirrored images from the customer's own Artifact Registry —
# mirrors AWS's AmazonEC2ContainerRegistryReadOnly policy on the node role.
resource "google_service_account" "gke_node" {
  project      = var.project_id
  account_id   = "${var.cluster_name}-node"
  display_name = "GKE node SA for ${var.cluster_name}"

  depends_on = [google_project_service.required]
}

resource "google_project_iam_member" "gke_node_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.gke_node.email}"
}

resource "google_project_iam_member" "gke_node_metrics" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.gke_node.email}"
}

resource "google_project_iam_member" "gke_node_monitoring_viewer" {
  project = var.project_id
  role    = "roles/monitoring.viewer"
  member  = "serviceAccount:${google_service_account.gke_node.email}"
}

resource "google_project_iam_member" "gke_node_artifact_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.gke_node.email}"
}

resource "google_container_cluster" "main" {
  project  = var.project_id
  name     = var.cluster_name
  location = local.cluster_location

  # Managed separately below (system pool) — Karpenter provisions/removes
  # every application node pool dynamically, so there's nothing for a
  # cluster-managed "default" pool to do.
  remove_default_node_pool = true
  initial_node_count       = 1

  network    = google_compute_network.main.id
  subnetwork = google_compute_subnetwork.main.id

  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_secondary_range_name  = "${var.cluster_name}-pods"
    services_secondary_range_name = "${var.cluster_name}-services"
  }

  # Public endpoint, same posture as terraform/aws/eks's
  # cluster_endpoint_public_access = true — nodes themselves stay private
  # (no external IPs) behind the Cloud NAT in network.tf.
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
  }

  # Workload Identity — GCP's equivalent of EKS Pod Identity/IRSA. Every K8s
  # ServiceAccount that needs GCP permissions (straiker-artifact-hauler,
  # straiker-inference, straiker-defend, Karpenter's own controller) binds to
  # a GCP service account via this pool rather than node-wide credentials.
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  release_channel {
    channel = "REGULAR"
  }

  deletion_protection = false
}

# Minimal always-on node pool for Karpenter's own controller + core cluster
# addons (CoreDNS, etc.) — Karpenter manages every application-workload node
# pool dynamically from here, mirroring terraform/aws/eks's
# eks_managed_node_groups.system (fixed size, tainted so only
# CriticalAddonsOnly-tolerating pods land here).
resource "google_container_node_pool" "system" {
  project        = var.project_id
  name           = "system"
  location       = local.cluster_location
  node_locations = local.system_node_locations
  cluster        = google_container_cluster.main.name
  node_count     = var.system_node_count

  node_config {
    machine_type    = var.system_node_machine_type
    service_account = google_service_account.gke_node.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    labels = {
      "node.kubernetes.io/purpose" = "system"
    }

    taint {
      key    = "CriticalAddonsOnly"
      value  = "true"
      effect = "NO_SCHEDULE"
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}
