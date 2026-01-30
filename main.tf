terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = ">= 3.29.0"
    }
    local = {
      source = "hashicorp/local"
    }
  }
  required_version = ">= 1.1.0"
}

# ==============================================================================
# VARIABLES (set via environment variables: TF_VAR_<name>)
# ==============================================================================
variable "cloudflare_api_token" {
  description = "Cloudflare API Token with Gateway permissions (env: TF_VAR_cloudflare_api_token)"
  type        = string
  sensitive   = true
}

variable "cloudflare_account_id" {
  description = "Cloudflare Account ID (env: TF_VAR_cloudflare_account_id)"
  type        = string
}

# ==============================================================================
# LOCALS
# ==============================================================================
locals {
  cloudflare_account_id = var.cloudflare_account_id
}

# ==============================================================================
# PROVIDER
# ==============================================================================
provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
