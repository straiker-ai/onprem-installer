variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
}

variable "prefix" {
  description = "Prefix for resource names (Artifact Registry repo, GCS bucket, service accounts)"
  type        = string
  default     = "s6r-onprem"
}

variable "cluster_name" {
  description = "GKE cluster name. Only used for resource tagging/labels here — Workload Identity bindings need project + namespace + KSA name, not cluster name."
  type        = string
  default     = "s6r-onprem"
}

variable "namespace" {
  description = "Kubernetes namespace the hauling Job's ServiceAccount runs in"
  type        = string
  default     = "straiker"
}

variable "service_account_name" {
  description = "Kubernetes ServiceAccount name the hauling Job runs as"
  type        = string
  default     = "straiker-artifact-hauler"
}

variable "workload_namespace" {
  description = "Namespace of the workload that reads models from GCS. Leave empty to create the reader SA without binding it yet."
  type        = string
  default     = ""
}

variable "workload_service_account_names" {
  description = "ServiceAccount names (in workload_namespace) that read models from GCS — one binding per name, all to the same reader SA (e.g. straiker-inference's shared SA, straiker-defend's SA). Leave empty to skip Workload Identity bindings entirely."
  type        = list(string)
  default     = []
}
