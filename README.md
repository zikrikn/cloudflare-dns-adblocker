# Serverless Ad Blocking with Cloudflare Gateway

This module automates the setup needed to mimic the Pi-hole's behaviour using only serverless technologies (Cloudflare Gateway, to be precise),
as described in [Serverless Ad Blocking with Cloudflare Gateway](https://blog.marcolancini.it/2022/blog-serverless-ad-blocking-with-cloudflare-gateway/).


## Prerequisites

1. A Cloudflare account with Zero Trust enabled
2. A Cloudflare API Token with Gateway permissions
3. Terraform >= 1.1.0


## Setup

1. Clone this repository
2. Copy `terraform.tfvars.example` to `terraform.tfvars`:
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```
3. Edit `terraform.tfvars` and fill in your Cloudflare credentials:
   - `cloudflare_account_id`: Your Cloudflare Account ID (found in the Cloudflare dashboard)
   - `cloudflare_api_token`: An API token with Gateway Edit permissions

4. Initialize and apply Terraform:
   ```bash
   terraform init
   terraform plan
   terraform apply
   ```


## Deploying Resources

In short, this module creates:

* A set of Cloudflare Lists which contain the list of domains to block
* A Cloudflare Gateway Policy which blocks access (at the DNS level) to those domains

![](https://blog.marcolancini.it/images/posts/blog_serverless_adblocking_policies.png)


## Keeping the domain list up to date

The `.github/workflows/update-lists.yml` provides a GitHub Actions workflow that periodically (monthly on the 15th) 
fetches the domain list from upstream (adaway.org) and creates a Pull Request if it has changed.

To enable:
1. Push this repository to GitHub
2. The workflow runs automatically on the 15th of each month
3. You can also trigger it manually via "Actions" → "Update Domain List" → "Run workflow"

![](https://blog.marcolancini.it/images/posts/blog_serverless_adblocking_gh_workflow.png)
