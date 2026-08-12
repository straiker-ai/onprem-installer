variable "prefix" {
  description = "Prefix for the state bucket and lock table names"
  type        = string
  default     = "s6r-onprem"
}

variable "region" {
  description = "AWS region"
  type        = string
}
