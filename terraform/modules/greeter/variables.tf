variable "release_name" {
  description = "Helm release name."
  type        = string
}

variable "namespace" {
  description = "Namespace to deploy into. Created if it does not exist."
  type        = string
}

variable "chart_path" {
  description = "Path to the local greeter Helm chart."
  type        = string
}

variable "greeting_name" {
  description = "Value for GREETING_NAME. Required by the app; must not be empty."
  type        = string

  validation {
    condition     = length(var.greeting_name) > 0
    error_message = "greeting_name must not be empty (the app exits non-zero without it)."
  }
}

variable "replica_count" {
  description = "Number of pod replicas."
  type        = number
}

variable "app_version" {
  description = "Value for VERSION; surfaced on /version and in greeter_build_info."
  type        = string
}

variable "ingress_host" {
  description = "Host the ingress routes for this environment (e.g. dev.localhost)."
  type        = string
}

variable "image_repository" {
  description = "Container image repository."
  type        = string
  default     = "greeter"
}

variable "image_tag" {
  description = "Container image tag."
  type        = string
  default     = "dev"
}
