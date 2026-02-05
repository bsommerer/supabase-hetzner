terraform {
  required_version = ">= 1.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.45"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }

  # Optional: Remote Backend für Terraform State in Hetzner S3
  # Auskommentieren und anpassen wenn gewünscht
  # backend "s3" {
  #   bucket                      = "terraform-state"
  #   key                         = "supabase-hetzner/terraform.tfstate"
  #   region                      = "eu-central-1"
  #   endpoint                    = "https://fsn1.your-objectstorage.com"
  #   skip_credentials_validation = true
  #   skip_metadata_api_check     = true
  #   skip_region_validation      = true
  #   force_path_style            = true
  # }
}

provider "hcloud" {
  token = var.hcloud_token
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
