# prod environment.
#
# Same module as dev, different values: more replicas for availability, a prod
# greeting and version, and its own namespace and host. Three replicas spread
# across the two workers as 2-1, which still tolerates losing one node.

provider "helm" {
  kubernetes {
    config_path    = pathexpand(var.kubeconfig)
    config_context = var.kube_context
  }
}

module "greeter" {
  source = "../../modules/greeter"

  release_name = "greeter-prod"
  namespace    = "greeter-prod"
  chart_path   = "${path.module}/../../../deploy/greeter"

  greeting_name = "Prod"
  replica_count = 3
  app_version   = "1.0.0"
  ingress_host  = "prod.localhost"

  image_repository = "greeter"
  image_tag        = "dev"
}

output "url" {
  description = "Where the prod service is reachable."
  value       = module.greeter.url
}
