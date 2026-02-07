#!/bin/bash

# ==============================================================================
# Cloudflare Gateway Ad-Blocking Management Script
# Mengelola DNS policies dan lists via Cloudflare API langsung
# ==============================================================================

# Konfigurasi via environment variables
# Set CLOUDFLARE_ACCOUNT_ID dan CLOUDFLARE_API_TOKEN sebelum menjalankan script
ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID}"
API_TOKEN="${CLOUDFLARE_API_TOKEN}"

if [ -z "$ACCOUNT_ID" ] || [ -z "$API_TOKEN" ]; then
    echo -e "${RED}Error: CLOUDFLARE_ACCOUNT_ID dan CLOUDFLARE_API_TOKEN harus di-set!${NC}"
    echo "Export environment variables:"
    echo "  export CLOUDFLARE_ACCOUNT_ID=your_account_id"
    echo "  export CLOUDFLARE_API_TOKEN=your_api_token"
    exit 1
fi

API_BASE="https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}"
DOMAIN_LIST_FILE="./cloudflare/lists/pihole_domain_list.txt"
MAX_ITEMS_PER_LIST=1000

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================

api_request() {
    local method=$1
    local endpoint=$2
    local data=$3
    
    if [ -n "$data" ]; then
        curl -s -X "$method" "${API_BASE}${endpoint}" \
            -H "Authorization: Bearer ${API_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "$data"
    else
        curl -s -X "$method" "${API_BASE}${endpoint}" \
            -H "Authorization: Bearer ${API_TOKEN}" \
            -H "Content-Type: application/json"
    fi
}

# ==============================================================================
# DELETE FUNCTIONS
# ==============================================================================

delete_all_policies() {
    echo -e "${YELLOW}Fetching 'Block Ads' policy...${NC}"
    
    # Get all gateway rules
    local response=$(api_request "GET" "/gateway/rules")
    # Only select the "Block Ads" policy created by this script
    local policies=$(echo "$response" | jq -r '.result[] | select(.name == "Block Ads") | .id')
    
    if [ -z "$policies" ]; then
        echo -e "${GREEN}No 'Block Ads' policy found.${NC}"
        return
    fi
    
    echo -e "${YELLOW}Deleting 'Block Ads' policy...${NC}"
    for policy_id in $policies; do
        local name=$(echo "$response" | jq -r ".result[] | select(.id == \"$policy_id\") | .name")
        echo -n "  Deleting policy: $name ($policy_id)... "
        local del_response=$(api_request "DELETE" "/gateway/rules/${policy_id}")
        if echo "$del_response" | jq -e '.success' > /dev/null 2>&1; then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${RED}FAILED${NC}"
            echo "$del_response" | jq '.errors'
        fi
    done
}

delete_all_lists() {
    echo -e "${YELLOW}Fetching all Zero Trust lists...${NC}"
    
    # Get all lists
    local response=$(api_request "GET" "/gateway/lists")
    local lists=$(echo "$response" | jq -r '.result[] | select(.name | startswith("pihole_domain_list")) | .id')
    
    if [ -z "$lists" ]; then
        echo -e "${GREEN}No pihole lists found.${NC}"
        return
    fi
    
    echo -e "${YELLOW}Deleting pihole lists...${NC}"
    local count=0
    local total=$(echo "$lists" | wc -l)
    
    for list_id in $lists; do
        count=$((count + 1))
        local name=$(echo "$response" | jq -r ".result[] | select(.id == \"$list_id\") | .name")
        echo -ne "\r  Deleting list $count/$total: $name...          "
        local del_response=$(api_request "DELETE" "/gateway/lists/${list_id}")
        if ! echo "$del_response" | jq -e '.success' > /dev/null 2>&1; then
            echo -e "\n${RED}FAILED: $name${NC}"
            echo "$del_response" | jq '.errors'
        fi
        # Small delay to avoid rate limiting
        sleep 0.1
    done
    echo -e "\n${GREEN}Deleted $count lists.${NC}"
}

# ==============================================================================
# CREATE FUNCTIONS
# ==============================================================================

create_lists() {
    echo -e "${YELLOW}Reading domain list from ${DOMAIN_LIST_FILE}...${NC}"
    
    if [ ! -f "$DOMAIN_LIST_FILE" ]; then
        echo -e "${RED}Error: Domain list file not found!${NC}"
        exit 1
    fi
    
    # Read and clean the domain list
    local domains=$(grep -v '^#' "$DOMAIN_LIST_FILE" | grep -v '^$' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    local total_domains=$(echo "$domains" | wc -l)
    local num_lists=$(( (total_domains + MAX_ITEMS_PER_LIST - 1) / MAX_ITEMS_PER_LIST ))
    
    echo -e "${GREEN}Found $total_domains domains, will create $num_lists lists.${NC}"
    
    local list_ids=()
    local chunk_num=0
    
    # Split into chunks and create lists
    echo "$domains" | split -l $MAX_ITEMS_PER_LIST -d -a 3 - /tmp/domain_chunk_
    
    for chunk_file in /tmp/domain_chunk_*; do
        local chunk_name=$(printf "pihole_domain_list_%03d" $chunk_num)
        echo -ne "\r  Creating list $((chunk_num + 1))/$num_lists: $chunk_name...          "
        
        # Build items array for API
        local items=$(cat "$chunk_file" | jq -R '{"value": .}' | jq -s '.')
        
        local payload=$(jq -n \
            --arg name "$chunk_name" \
            --argjson items "$items" \
            '{name: $name, type: "DOMAIN", items: $items}')
        
        local response=$(api_request "POST" "/gateway/lists" "$payload")
        
        if echo "$response" | jq -e '.success' > /dev/null 2>&1; then
            local list_id=$(echo "$response" | jq -r '.result.id')
            list_ids+=("$list_id")
        else
            echo -e "\n${RED}FAILED to create $chunk_name${NC}"
            echo "$response" | jq '.errors'
        fi
        
        rm -f "$chunk_file"
        chunk_num=$((chunk_num + 1))
        
        # Small delay to avoid rate limiting
        sleep 0.2
    done
    
    echo -e "\n${GREEN}Created $chunk_num lists.${NC}"
    
    # Save list IDs for policy creation
    printf '%s\n' "${list_ids[@]}" > /tmp/created_list_ids.txt
}

create_policy() {
    echo -e "${YELLOW}Creating Block Ads policy...${NC}"
    
    if [ ! -f /tmp/created_list_ids.txt ]; then
        echo -e "${RED}Error: No list IDs found. Run create_lists first.${NC}"
        exit 1
    fi
    
    # Build the traffic filter expression
    local filters=""
    while read -r list_id; do
        if [ -n "$list_id" ]; then
            if [ -n "$filters" ]; then
                filters="${filters} or "
            fi
            filters="${filters}any(dns.domains[*] in \$${list_id})"
        fi
    done < /tmp/created_list_ids.txt
    
    if [ -z "$filters" ]; then
        echo -e "${RED}Error: No valid list IDs found.${NC}"
        exit 1
    fi
    
    local payload=$(jq -n \
        --arg name "Block Ads" \
        --arg description "Block Ads domains" \
        --arg traffic "$filters" \
        '{
            name: $name,
            description: $description,
            enabled: true,
            precedence: 11,
            filters: ["dns"],
            action: "block",
            traffic: $traffic,
            rule_settings: {
                block_page_enabled: false
            }
        }')
    
    local response=$(api_request "POST" "/gateway/rules" "$payload")
    
    if echo "$response" | jq -e '.success' > /dev/null 2>&1; then
        echo -e "${GREEN}Policy created successfully!${NC}"
        echo "$response" | jq '.result | {id, name, enabled}'
    else
        echo -e "${RED}Failed to create policy${NC}"
        echo "$response" | jq '.errors'
    fi
    
    rm -f /tmp/created_list_ids.txt
}

# ==============================================================================
# MAIN
# ==============================================================================

show_help() {
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  delete-policies  - Delete all DNS gateway policies"
    echo "  delete-lists     - Delete all pihole domain lists"
    echo "  delete-all       - Delete policies first, then lists"
    echo "  create-lists     - Create lists from domain file"
    echo "  create-policy    - Create Block Ads policy (run after create-lists)"
    echo "  apply            - Create lists and policy"
    echo "  reset            - Delete all, then apply (full reset)"
    echo ""
}

case "$1" in
    delete-policies)
        delete_all_policies
        ;;
    delete-lists)
        delete_all_lists
        ;;
    delete-all)
        delete_all_policies
        echo ""
        delete_all_lists
        ;;
    create-lists)
        create_lists
        ;;
    create-policy)
        create_policy
        ;;
    apply)
        create_lists
        echo ""
        create_policy
        ;;
    reset)
        delete_all_policies
        echo ""
        delete_all_lists
        echo ""
        echo -e "${YELLOW}Waiting 5 seconds before creating new resources...${NC}"
        sleep 5
        create_lists
        echo ""
        create_policy
        ;;
    *)
        show_help
        exit 1
        ;;
esac

echo ""
echo -e "${GREEN}Done!${NC}"
