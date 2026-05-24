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
