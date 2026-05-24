terraform {
  required_version = ">= 1.5"
  required_providers {
    google  = { source = "hashicorp/google", version = "~> 6.0" }
    archive = { source = "hashicorp/archive", version = "~> 2.4" }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "europe-west1"
}

variable "docai_location" {
  type    = string
  default = "eu"
}

# APIs -------------------------------------------------------------------------
resource "google_project_service" "apis" {
  for_each = toset([
    "cloudfunctions.googleapis.com",
    "run.googleapis.com",
    "cloudbuild.googleapis.com",
    "artifactregistry.googleapis.com",
    "eventarc.googleapis.com",
    "storage.googleapis.com",
    "documentai.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false
}

# Buckets: input (PDFs) + output (JSON) + code (function zip) ------------------
resource "google_storage_bucket" "input" {
  name                        = "${var.project_id}-pdf-input"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true
  depends_on                  = [google_project_service.apis]
}

resource "google_storage_bucket" "output" {
  name                        = "${var.project_id}-pdf-output"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true
  depends_on                  = [google_project_service.apis]
}

resource "google_storage_bucket" "code" {
  name                        = "${var.project_id}-pdf-code"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true
  depends_on                  = [google_project_service.apis]
}

# Document AI OCR processor ----------------------------------------------------
resource "google_document_ai_processor" "ocr" {
  location     = var.docai_location
  display_name = "pdf-poc-ocr"
  type         = "OCR_PROCESSOR"
  depends_on   = [google_project_service.apis]
}

# IAM --------------------------------------------------------------------------
data "google_project" "p" {}
data "google_storage_project_service_account" "gcs" {}

locals {
  fn_sa = "${data.google_project.p.number}-compute@developer.gserviceaccount.com"
}

resource "google_project_iam_member" "fn_roles" {
  for_each = toset([
    "roles/storage.objectAdmin",
    "roles/documentai.apiUser",
    "roles/eventarc.eventReceiver",
    "roles/run.invoker",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${local.fn_sa}"
}

# Required by Eventarc to deliver GCS object events.
resource "google_project_iam_member" "gcs_event_publisher" {
  project = var.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${data.google_storage_project_service_account.gcs.email_address}"
}

# Function + trigger -----------------------------------------------------------
data "archive_file" "src" {
  type        = "zip"
  source_dir  = "${path.module}/../function_source"
  output_path = "${path.module}/.build/src.zip"
}

resource "google_storage_bucket_object" "src" {
  name   = "src-${data.archive_file.src.output_md5}.zip"
  bucket = google_storage_bucket.code.name
  source = data.archive_file.src.output_path
}

resource "google_cloudfunctions2_function" "fn" {
  name     = "pdf-processor"
  location = var.region

  build_config {
    runtime     = "python311"
    entry_point = "process_pdf"
    source {
      storage_source {
        bucket = google_storage_bucket.code.name
        object = google_storage_bucket_object.src.name
      }
    }
  }

  service_config {
    available_memory   = "512Mi"
    timeout_seconds    = 300
    max_instance_count = 5
    environment_variables = {
      OUTPUT_BUCKET      = google_storage_bucket.output.name
      DOCAI_PROCESSOR_ID = "projects/${var.project_id}/locations/${var.docai_location}/processors/${google_document_ai_processor.ocr.name}"
      DOCAI_LOCATION     = var.docai_location
    }
  }

  event_trigger {
    trigger_region = var.region
    event_type     = "google.cloud.storage.object.v1.finalized"
    retry_policy   = "RETRY_POLICY_RETRY"
    event_filters {
      attribute = "bucket"
      value     = google_storage_bucket.input.name
    }
  }

  depends_on = [
    google_project_iam_member.fn_roles,
    google_project_iam_member.gcs_event_publisher,
  ]
}

output "input_bucket" { value = google_storage_bucket.input.name }
output "output_bucket" { value = google_storage_bucket.output.name }
