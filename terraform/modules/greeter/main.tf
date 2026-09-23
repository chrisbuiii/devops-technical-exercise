# A single helm_release, parameterised so every environment reuses it. The
# environment-specific differences (greeting, replicas, version, host) come in
# as variables; nothing here is duplicated per environment.
resource "helm_release" "greeter" {
  name             = var.release_name
  namespace        = var.namespace
  create_namespace = true

  chart = var.chart_path

  # Wait for the release to become healthy so `terraform apply` fails loudly if
  # a rollout does not go green, rather than reporting success too early.
  wait    = true
  timeout = 180

  # Recreate pods if an upgrade only changes values that the chart wires through
  # the ConfigMap checksum; keeps apply behaviour predictable.
  set {
    name  = "config.greetingName"
    value = var.greeting_name
  }

  set {
    name  = "config.version"
    value = var.app_version
  }

  set {
    name  = "replicaCount"
    value = var.replica_count
  }

  set {
    name  = "image.repository"
    value = var.image_repository
  }

  set {
    name  = "image.tag"
    value = var.image_tag
  }

  set {
    name  = "ingress.host"
    value = var.ingress_host
  }
}
