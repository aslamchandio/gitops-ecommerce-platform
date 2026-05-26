# GKE Standard regional cluster with:
#  - Default node pool removed
#  - A minimal "system" pool for kube-system / DaemonSets
#  - Node Auto-Provisioning (NAP) enabled so workload nodes are created on demand
#  - Gateway API controller enabled (CHANNEL_STANDARD)
#  - ComputeClass for app workloads is defined in k8s/05-compute-class.yaml,
#    which targets Spot VMs with on-demand fallback.

# Discover the zones available in var.region so NAP and the system pool don't
# need a hardcoded zone list. Flipping var.region re-derives the right zones
# automatically; a new zone added to the region by GCP is picked up on next
# `terraform apply`.
data "google_compute_zones" "available" {
  region = var.region
  status = "UP"
}

resource "google_container_cluster" "primary" {
  name     = var.cluster_name
  location = var.region # regional control plane = HA

  # We replace the default pool with our own minimal system pool below.
  remove_default_node_pool = true
  initial_node_count       = 1

  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.subnet.id

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # ---- Private cluster ----
  # Nodes get only internal IPs (no public IP — outbound via Cloud NAT).
  # The control plane endpoint stays public so kubectl works from a laptop,
  # but is locked down by master_authorized_networks below.
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = var.master_ipv4_cidr_block

    master_global_access_config {
      enabled = true
    }
  }

  # ---- Control plane DNS endpoint ----
  # Enables the DNS-based control plane endpoint
  # (gke-<id>-<project>.<region>.gke.goog) in addition to the IP endpoint.
  # The DNS endpoint is gated by IAM (roles/container.viewer or higher)
  # instead of master_authorized_networks CIDR allowlists — handy when
  # connecting from a laptop with a dynamic IP, CI runners, or anywhere
  # the source IP can't be pinned. Get a kubeconfig with it via:
  #
  #   gcloud container clusters get-credentials <cluster> \
  #     --region <region> --dns-endpoint
  control_plane_endpoints_config {
    dns_endpoint_config {
      allow_external_traffic = true
    }
  }

  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.master_authorized_networks
      content {
        cidr_block   = cidr_blocks.value
        display_name = "authorized-${replace(cidr_blocks.value, "/", "-")}"
      }
    }
  }

  release_channel {
    channel = var.release_channel
  }

  # Enable the Kubernetes Gateway API controller (provides
  # `gke-l7-global-external-managed` and friends).
  gateway_api_config {
    channel = var.gateway_api_channel
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Node Auto-Provisioning: when a pod is unschedulable, GKE creates a new
  # node pool sized for the pod's resource requests + the ComputeClass it
  # asks for. Pools scale back to zero when idle.
  cluster_autoscaling {
    enabled = true

    resource_limits {
      resource_type = "cpu"
      minimum       = 1
      maximum       = var.nap_cpu_limit
    }
    resource_limits {
      resource_type = "memory"
      minimum       = 1
      maximum       = var.nap_memory_limit_gb
    }

    # Restrict NAP to the zones the region exposes today. Authoritative for
    # ALL ComputeClass-driven node creation in this cluster — the k8s
    # ComputeClass intentionally omits its own location.zones so it inherits
    # from here (single source of truth).
    auto_provisioning_locations = data.google_compute_zones.available.names

    auto_provisioning_defaults {
      service_account = google_service_account.gke_nodes.email
      oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
      disk_type       = var.nap_disk_type
      disk_size       = var.nap_disk_size_gb

      management {
        auto_repair  = true
        auto_upgrade = true
      }

      shielded_instance_config {
        enable_secure_boot          = true
        enable_integrity_monitoring = true
      }
    }
  }

  addons_config {
    horizontal_pod_autoscaling { disabled = false }
    http_load_balancing        { disabled = false }
    network_policy_config      { disabled = false }
  }

  # Installs the Secret Manager CSI driver and registers the
  # SecretProviderClass CRD in the cluster.
  secret_manager_config {
    enabled = true
  }

  # Cloud Logging + Cloud Monitoring + Managed Service for Prometheus.
  # GMP gives us a PodMonitoring CRD; apps that expose /metrics or
  # /actuator/prometheus get scraped automatically and their metrics
  # land in Cloud Monitoring's Prometheus dashboard + are queryable
  # via PromQL from Grafana with the GMP datasource.
  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
    managed_prometheus {
      enabled = true
    }
  }

  deletion_protection = false
  depends_on          = [google_project_service.enabled]
}

# Minimal pool that hosts kube-system, DNS, metrics — anything we don't want
# evicted by a Spot reclamation event.
resource "google_container_node_pool" "system" {
  name     = var.system_pool_name
  cluster  = google_container_cluster.primary.name
  location = google_container_cluster.primary.location

  # nodes per zone → multiplied by zones in a regional cluster
  node_count = var.system_node_count

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type    = var.system_node_machine_type
    disk_size_gb    = var.system_node_disk_size_gb
    disk_type       = var.system_node_disk_type
    service_account = google_service_account.gke_nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    labels = {
      "workload" = "system"
    }
    # Tainted so only system-tolerant pods land here. NAP-created Spot
    # nodes for app workloads carry the cloud.google.com/gke-spot taint
    # which app deployments tolerate explicitly.
    taint {
      key    = "workload"
      value  = "system"
      effect = "PREFER_NO_SCHEDULE"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }
}
