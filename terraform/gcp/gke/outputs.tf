output "configure_kubectl" {
  description = "Run this to configure kubectl after apply"
  value       = "gcloud container clusters get-credentials ${google_container_cluster.main.name} --region ${var.region} --project ${var.project_id}"
}

output "cluster_name" {
  value = google_container_cluster.main.name
}

output "cluster_endpoint" {
  value = google_container_cluster.main.endpoint
}

output "cluster_ca_certificate" {
  value     = google_container_cluster.main.master_auth[0].cluster_ca_certificate
  sensitive = true
}

output "network_name" {
  value = google_compute_network.main.name
}

output "subnetwork_name" {
  value = google_compute_subnetwork.main.name
}

output "gke_node_service_account_email" {
  value = google_service_account.gke_node.email
}

output "karpenter_service_account_email" {
  value = google_service_account.karpenter.email
}

output "karpenter_node_service_account_email" {
  value = google_service_account.karpenter_node.email
}

output "workload_identity_pool" {
  value = "${var.project_id}.svc.id.goog"
}
