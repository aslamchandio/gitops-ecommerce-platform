resource "random_password" "db_password" {
  length  = var.db_password_length
  special = false
}

resource "google_sql_database_instance" "postgres" {
  name             = var.db_instance_name
  database_version = var.db_version
  region           = var.region

  settings {
    tier              = var.db_tier
    edition           = var.db_edition           # ENTERPRISE allows shared-core tiers
    availability_type = var.db_availability_type # ZONAL = cheaper; REGIONAL = HA
    disk_size         = var.db_disk_size_gb
    disk_type         = var.db_disk_type

    ip_configuration {
      ipv4_enabled                                  = false
      private_network                               = google_compute_network.vpc.id
      enable_private_path_for_google_cloud_services = true
    }

    backup_configuration {
      enabled    = true
      start_time = var.db_backup_start_time
    }

    # max_connections raised from the db-f1-micro default (~25) to 75 so
    # 2 replicas × HikariCP-of-5 across catalog + order leaves headroom for
    # idle connections, the migrate step, k8s probes, and Cloud SQL's own
    # superuser reservation. 75 × ~10MB = ~750MB which fits in the f1-micro
    # 0.6GB instance because Cloud SQL accounts for actual usage, not peak;
    # in practice we burn well under that.
    database_flags {
      name  = "max_connections"
      value = "75"
    }
  }

  deletion_protection = false
  depends_on          = [google_service_networking_connection.private_vpc]
}

resource "google_sql_database" "catalog" {
  name     = var.db_name_catalog
  instance = google_sql_database_instance.postgres.name
}

resource "google_sql_database" "orders" {
  name     = var.db_name_orders
  instance = google_sql_database_instance.postgres.name
}

resource "google_sql_user" "app" {
  name     = var.db_user
  instance = google_sql_database_instance.postgres.name
  password = random_password.db_password.result
}
