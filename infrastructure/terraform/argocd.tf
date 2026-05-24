# ArgoCD installed via the official argo-cd Helm chart.
# The server is exposed through a regional Network LoadBalancer, restricted
# to the same IP allow-list as the GKE control plane (no public exposure).
#
# Login after apply:
#   1. terraform output argocd_password_command   # prints the kubectl command
#   2. run it to get the initial admin password
#   3. browse to http://<argocd_url>  (or use `argocd login <ip>`)

resource "kubernetes_namespace" "argocd" {
  metadata {
    name = var.argocd_namespace
  }

  depends_on = [google_container_node_pool.system]
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version
  namespace  = kubernetes_namespace.argocd.metadata[0].name

  # Block until all deployments are healthy so the data source below can read
  # the LB IP immediately on the next plan.
  wait    = true
  timeout = 600

  values = [yamlencode({
    # ----- argocd-server (the UI + API) -----
    server = {
      # Serve plain HTTP. The LB is locked down to your IP via
      # loadBalancerSourceRanges, so no MITM risk on the public internet.
      # Skip this flag if you want self-signed TLS instead.
      extraArgs = ["--insecure"]
      service = {
        type                     = "LoadBalancer"
        loadBalancerSourceRanges = var.master_authorized_networks
        servicePortHttp          = 80
        servicePortHttps         = 443
      }
    }

    # configs.params mirrors what --insecure does, via the configmap path.
    configs = {
      params = {
        "server.insecure" = true
      }
    }
  })]

  depends_on = [
    google_container_node_pool.system,
    # Make sure the cluster's GKE addons are settled before installing more workloads
    google_container_cluster.primary,
  ]
}

# Read the LB IP after the helm release has finished rolling out.
data "kubernetes_service" "argocd_server" {
  metadata {
    name      = "argocd-server"
    namespace = kubernetes_namespace.argocd.metadata[0].name
  }
  depends_on = [helm_release.argocd]
}
