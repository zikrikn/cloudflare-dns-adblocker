# ==============================================================================
# POLICY: Block Ads
# ==============================================================================
locals {
  # Iterate through each pihole_domain_list resource and extract its ID
  # Only include lists that have actual domains (not placeholder)
  pihole_domain_lists = [
    for k, v in cloudflare_teams_list.pihole_domain_lists : v.id
    if length(v.items) > 0 && !contains(tolist(v.items), "placeholder.invalid")
  ]

  # Create filters to use in the policy - format: any(dns.domains[*] in $<list_id>)
  pihole_ad_filters = [for id in local.pihole_domain_lists : format("any(dns.domains[*] in $%s)", id)]
  pihole_ad_filter  = length(local.pihole_ad_filters) > 0 ? join(" or ", local.pihole_ad_filters) : "dns.fqdn == \"placeholder.invalid\""
}

resource "cloudflare_teams_rule" "block_ads" {
  account_id = local.cloudflare_account_id

  name        = "Block Ads"
  description = "Block Ads domains"

  enabled    = true
  precedence = 11

  # Block domain belonging to lists (defined below)
  filters = ["dns"]
  action  = "block"
  traffic = local.pihole_ad_filter

  rule_settings {
    block_page_enabled = false
  }
}


# ==============================================================================
# LISTS: AD Blocking domain list
#
# Remote source:
#   - https://firebog.net/
#   - https://adaway.org/hosts.txt
# Local file:
#   - ./cloudflare/lists/pihole_domain_list.txt
#   - the file can be updated periodically via Github Actions (see README)
# ==============================================================================
locals {
  # The full path of the list holding the domain list
  pihole_domain_list_file = "${path.module}/cloudflare/lists/pihole_domain_list.txt"

  # Parse the file and create a list, one item per line
  pihole_domain_list = split("\n", file(local.pihole_domain_list_file))

  # Remove empty lines and comments (lines starting with #)
  pihole_domain_list_clean = [for x in local.pihole_domain_list : trimspace(x) if trimspace(x) != "" && !startswith(trimspace(x), "#")]

  # Use chunklist to split a list into fixed-size chunks
  # It returns a list of lists
  pihole_aggregated_lists = chunklist(local.pihole_domain_list_clean, 1000)

  # Get the number of lists (chunks) created
  pihole_list_count = length(local.pihole_aggregated_lists)

  # Fixed number of list slots - adjust this if you need more
  # This prevents Terraform from ever deleting lists
  max_list_slots = 15
}

resource "cloudflare_teams_list" "pihole_domain_lists" {
  account_id = local.cloudflare_account_id

  for_each = {
    for i in range(0, local.max_list_slots) :
    format("%03d", i) => i < local.pihole_list_count ? element(local.pihole_aggregated_lists, i) : ["placeholder.invalid"]
  }

  name  = "pihole_domain_list_${each.key}"
  type  = "DOMAIN"
  items = each.value
}
