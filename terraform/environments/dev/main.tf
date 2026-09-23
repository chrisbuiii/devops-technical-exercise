# dev environment.
#
# Differs from prod only in the values passed to the shared module: a smaller
# replica count, a dev greeting and version, and its own namespace and host.

provider "helm" {
  kubernetes {
    config_path    = pathexpand(var.kubeconfig)
    config_context = var.kube_context
  }
}

module "greeter" {
  source = "../../modules/greeter"

  release_name = "greeter-dev"
  namespace    = "greeter-dev"
  chart_path   = "${path.module}/../../../deploy/greeter"

  greeting_name = "Dev"
  replica_count = 1
  app_version   = "dev"
  ingress_host  = "dev.localhost"

  image_repository = "greeter"
  image_tag        = "dev"
}

output "url" {
  description = "Where the dev service is reachable."
  value       = module.greeter.url
}
