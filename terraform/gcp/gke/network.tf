resource "google_compute_network" "main" {
  project                 = var.project_id
  name                    = var.cluster_name
  auto_create_subnetworks = false

  depends_on = [google_project_service.required]
}

# VPC-native (alias IP) cluster — GKE's default and required for Workload
# Identity — needs its own primary range plus two secondary ranges (pods,
# services), mirroring terraform/aws/eks's public/private subnet split
# conceptually (one range per traffic class rather than one per AZ, since
# GCP subnets are already regional, not zonal).
resource "google_compute_subnetwork" "main" {
  project       = var.project_id
  name          = var.cluster_name
  region        = var.region
  network       = google_compute_network.main.id
  ip_cidr_range = var.vpc_cidr

  secondary_ip_range {
    range_name    = "${var.cluster_name}-pods"
    ip_cidr_range = var.pods_cidr
  }
  secondary_ip_range {
    range_name    = "${var.cluster_name}-services"
    ip_cidr_range = var.services_cidr
  }

  private_ip_google_access = true
}

# Cloud NAT so nodes without external IPs (all of them — see gke.tf's
# enable_private_nodes) can still reach the internet (pull public images,
# reach Straiker's GAR source registry, etc.) — same role as
# terraform/aws/eks's NAT gateway.
resource "google_compute_router" "main" {
  project = var.project_id
  name    = "${var.cluster_name}-router"
  region  = var.region
  network = google_compute_network.main.id
}

resource "google_compute_router_nat" "main" {
  project                            = var.project_id
  name                               = "${var.cluster_name}-nat"
  router                             = google_compute_router.main.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}
