output "release_name" {
  description = "Name of the Helm release."
  value       = helm_release.greeter.name
}

output "namespace" {
  description = "Namespace the release is deployed into."
  value       = helm_release.greeter.namespace
}

output "url" {
  description = "URL the service is reachable on through the ingress."
  value       = "http://${var.ingress_host}/"
}
