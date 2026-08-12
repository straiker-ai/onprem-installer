variable "prefix" {
  description = "Prefix for the state bucket name"
  type        = string
  default     = "s6r-onprem"
}

variable "region" {
  description = "GCP region"
  type        = string
}

variable "project_id" {
  description = "GCP project ID"
  type        = string
}
