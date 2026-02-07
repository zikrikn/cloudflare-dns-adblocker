# ==============================================================================
# Cloudflare Gateway Ad-Blocking Management Script (PowerShell)
# ==============================================================================

param(
    [Parameter(Position=0)]
    [ValidateSet("delete-policies", "delete-lists", "delete-all", "create-lists", "create-policy", "apply", "reset", "help")]
    [string]$Command = "help"
)

# Konfigurasi via environment variables
# Set CLOUDFLARE_ACCOUNT_ID dan CLOUDFLARE_API_TOKEN sebelum menjalankan script
$ACCOUNT_ID = $env:CLOUDFLARE_ACCOUNT_ID
$API_TOKEN = $env:CLOUDFLARE_API_TOKEN

if (-not $ACCOUNT_ID -or -not $API_TOKEN) {
    Write-Host "Error: CLOUDFLARE_ACCOUNT_ID dan CLOUDFLARE_API_TOKEN harus di-set!" -ForegroundColor Red
    Write-Host "Set environment variables:"
    Write-Host '  $env:CLOUDFLARE_ACCOUNT_ID = "your_account_id"'
    Write-Host '  $env:CLOUDFLARE_API_TOKEN = "your_api_token"'
    exit 1
}

$API_BASE = "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID"
$DOMAIN_LIST_FILE = "$PSScriptRoot\cloudflare\lists\pihole_domain_list.txt"
$MAX_ITEMS_PER_LIST = 1000

$headers = @{
    "Authorization" = "Bearer $API_TOKEN"
    "Content-Type" = "application/json"
}

$script:CreatedListIds = @()

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================

function Invoke-CloudflareAPI {
    param(
        [string]$Method,
        [string]$Endpoint,
        [object]$Body = $null
    )
    
    $uri = "$API_BASE$Endpoint"
    
    try {
        if ($Body) {
            $jsonBody = $Body | ConvertTo-Json -Depth 10 -Compress
            $response = Invoke-RestMethod -Uri $uri -Method $Method -Headers $headers -Body $jsonBody -ErrorAction Stop
        } else {
            $response = Invoke-RestMethod -Uri $uri -Method $Method -Headers $headers -ErrorAction Stop
        }
        return $response
    } catch {
        return @{ success = $false; errors = @(@{ message = $_.Exception.Message }) }
    }
}

# ==============================================================================
# DELETE FUNCTIONS
# ==============================================================================

function Remove-AllPolicies {
    Write-Host "Fetching 'Block Ads' policy..." -ForegroundColor Yellow
    
    $response = Invoke-CloudflareAPI -Method "GET" -Endpoint "/gateway/rules"
    
    if (-not $response.result) {
        Write-Host "No policies found." -ForegroundColor Green
        return
    }
    
    # Only select the "Block Ads" policy created by this script
    $dnsPolicies = $response.result | Where-Object { $_.name -eq "Block Ads" }
    
    if ($dnsPolicies.Count -eq 0) {
        Write-Host "No 'Block Ads' policy found." -ForegroundColor Green
        return
    }
    
    Write-Host "Deleting 'Block Ads' policy..." -ForegroundColor Yellow
    foreach ($policy in $dnsPolicies) {
        Write-Host "  Deleting policy: $($policy.name) ($($policy.id))... " -NoNewline
        $delResponse = Invoke-CloudflareAPI -Method "DELETE" -Endpoint "/gateway/rules/$($policy.id)"
        if ($delResponse.success) {
            Write-Host "OK" -ForegroundColor Green
        } else {
            Write-Host "FAILED" -ForegroundColor Red
            Write-Host "    Error: $($delResponse.errors | ForEach-Object { $_.message })" -ForegroundColor Red
        }
    }
}

function Remove-AllLists {
    Write-Host "Fetching all Zero Trust lists..." -ForegroundColor Yellow
    
    $response = Invoke-CloudflareAPI -Method "GET" -Endpoint "/gateway/lists"
    
    if (-not $response.result) {
        Write-Host "No lists found." -ForegroundColor Green
        return
    }
    
    $piholeLists = $response.result | Where-Object { $_.name -like "pihole_domain_list*" }
    
    if ($piholeLists.Count -eq 0) {
        Write-Host "No pihole lists found." -ForegroundColor Green
        return
    }
    
    Write-Host "Deleting $($piholeLists.Count) pihole lists..." -ForegroundColor Yellow
    $count = 0
    foreach ($list in $piholeLists) {
        $count++
        $percent = [math]::Round(($count / $piholeLists.Count) * 100)
        Write-Progress -Activity "Deleting lists" -Status "$count of $($piholeLists.Count): $($list.name)" -PercentComplete $percent
        
        $delResponse = Invoke-CloudflareAPI -Method "DELETE" -Endpoint "/gateway/lists/$($list.id)"
        if (-not $delResponse.success) {
            Write-Host "`nFailed to delete: $($list.name)" -ForegroundColor Red
        }
        Start-Sleep -Milliseconds 100
    }
    Write-Progress -Activity "Deleting lists" -Completed
    Write-Host "Deleted $count lists." -ForegroundColor Green
}

# ==============================================================================
# CREATE FUNCTIONS
# ==============================================================================

function New-Lists {
    Write-Host "Reading domain list from $DOMAIN_LIST_FILE..." -ForegroundColor Yellow
    
    if (-not (Test-Path $DOMAIN_LIST_FILE)) {
        Write-Host "Error: Domain list file not found!" -ForegroundColor Red
        exit 1
    }
    
    # Read and clean domains
    $domains = Get-Content $DOMAIN_LIST_FILE | 
        Where-Object { $_ -notmatch '^\s*#' -and $_ -notmatch '^\s*$' } |
        ForEach-Object { $_.Trim() }
    
    $totalDomains = $domains.Count
    $numLists = [math]::Ceiling($totalDomains / $MAX_ITEMS_PER_LIST)
    
    Write-Host "Found $totalDomains domains, will create $numLists lists." -ForegroundColor Green
    
    $script:CreatedListIds = @()
    
    for ($i = 0; $i -lt $numLists; $i++) {
        $chunkName = "pihole_domain_list_{0:D3}" -f $i
        $startIdx = $i * $MAX_ITEMS_PER_LIST
        $chunk = $domains | Select-Object -Skip $startIdx -First $MAX_ITEMS_PER_LIST
        
        $percent = [math]::Round((($i + 1) / $numLists) * 100)
        Write-Progress -Activity "Creating lists" -Status "$($i + 1) of $numLists : $chunkName" -PercentComplete $percent
        
        $items = @($chunk | ForEach-Object { @{ value = $_ } })
        
        $body = @{
            name = $chunkName
            type = "DOMAIN"
            items = $items
        }
        
        $response = Invoke-CloudflareAPI -Method "POST" -Endpoint "/gateway/lists" -Body $body
        
        if ($response.success) {
            $script:CreatedListIds += $response.result.id
        } else {
            Write-Host "`nFailed to create $chunkName" -ForegroundColor Red
            Write-Host "  Error: $($response.errors | ForEach-Object { $_.message })" -ForegroundColor Red
        }
        
        Start-Sleep -Milliseconds 200
    }
    
    Write-Progress -Activity "Creating lists" -Completed
    Write-Host "Created $($script:CreatedListIds.Count) lists." -ForegroundColor Green
}

function New-Policy {
    Write-Host "Creating Block Ads policy..." -ForegroundColor Yellow
    
    if ($script:CreatedListIds.Count -eq 0) {
        Write-Host "Error: No list IDs found. Run create-lists first." -ForegroundColor Red
        exit 1
    }
    
    # Build traffic filter
    $filters = $script:CreatedListIds | ForEach-Object { "any(dns.domains[*] in `$$_)" }
    $traffic = $filters -join " or "
    
    $body = @{
        name = "Block Ads"
        description = "Block Ads domains"
        enabled = $true
        precedence = 11
        filters = @("dns")
        action = "block"
        traffic = $traffic
        rule_settings = @{
            block_page_enabled = $false
        }
    }
    
    $response = Invoke-CloudflareAPI -Method "POST" -Endpoint "/gateway/rules" -Body $body
    
    if ($response.success) {
        Write-Host "Policy created successfully!" -ForegroundColor Green
        Write-Host "  ID: $($response.result.id)"
        Write-Host "  Name: $($response.result.name)"
    } else {
        Write-Host "Failed to create policy" -ForegroundColor Red
        Write-Host "  Error: $($response.errors | ForEach-Object { $_.message })" -ForegroundColor Red
    }
}

# ==============================================================================
# MAIN
# ==============================================================================

function Show-Help {
    Write-Host @"
Usage: .\manage-gateway.ps1 <command>

Commands:
  delete-policies  - Delete all DNS gateway policies
  delete-lists     - Delete all pihole domain lists
  delete-all       - Delete policies first, then lists
  create-lists     - Create lists from domain file
  create-policy    - Create Block Ads policy (run after create-lists)
  apply            - Create lists and policy
  reset            - Delete all, then apply (full reset)
  help             - Show this help
"@
}

switch ($Command) {
    "delete-policies" { Remove-AllPolicies }
    "delete-lists" { Remove-AllLists }
    "delete-all" { 
        Remove-AllPolicies
        Write-Host ""
        Remove-AllLists
    }
    "create-lists" { New-Lists }
    "create-policy" { New-Policy }
    "apply" {
        New-Lists
        Write-Host ""
        New-Policy
    }
    "reset" {
        Remove-AllPolicies
        Write-Host ""
        Remove-AllLists
        Write-Host ""
        Write-Host "Waiting 5 seconds before creating new resources..." -ForegroundColor Yellow
        Start-Sleep -Seconds 5
        New-Lists
        Write-Host ""
        New-Policy
    }
    default { Show-Help }
}

Write-Host ""
Write-Host "Done!" -ForegroundColor Green
