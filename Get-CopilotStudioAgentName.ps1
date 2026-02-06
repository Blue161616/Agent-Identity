<#
.SYNOPSIS
  Find Copilot Studio agent name by Entra Agent ID (GUID) - searches ALL fields.

.EXAMPLE
  .\Get-CopilotStudioAgentName.ps1 `
    -EntraAgentObjectId "<Entra-Agent-Object-ID>" `
    -EnvironmentUrl "https://<PowerPlatformEnvironment>.crm4.dynamics.com" `
    -TenantId "Tenant-Id"
#>

param(
    [Parameter(Mandatory=$false)]
    [string] $EntraAgentObjectId,

    [Parameter(Mandatory)]
    [ValidatePattern('^https://.+$')]
    [string] $EnvironmentUrl,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string] $TenantId,

    [Parameter()]
    [switch] $VerboseLogging
)

if ([string]::IsNullOrWhiteSpace($EntraAgentObjectId)) {
    $EntraAgentObjectId = Read-Host "Enter Entra Agent Identity Object ID (GUID)"
}

if ($EntraAgentObjectId -notmatch '^[0-9a-fA-F-]{36}$') {
    throw "Invalid GUID format for EntraAgentObjectId: '$EntraAgentObjectId'"
}

$ErrorActionPreference = "Stop"

function LogInfo($msg) { 
    Write-Host ("[{0}] [Info] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg) 
}

function LogWarn($msg) { 
    Write-Host ("[{0}] [Warn] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg) -ForegroundColor Yellow 
}

function LogVerbose($msg) {
    if ($VerboseLogging) {
        Write-Host ("[{0}] [Verbose] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg) -ForegroundColor Cyan
    }
}

function Ensure-Module {
    param([Parameter(Mandatory)][string]$Name)
    
    if (-not (Get-Module -ListAvailable -Name $Name)) {
        LogInfo "Module '$Name' not found. Installing from PSGallery..."
        Install-Module $Name -Scope CurrentUser -Force
    }
    Import-Module $Name -Force
}

function Get-DataverseToken {
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$EnvironmentUrl
    )

    Ensure-Module -Name "MSAL.PS"
    $publicClientId = "04b07795-8ddb-461a-bbee-02f9e1bf7b46"
    $scope = "$EnvironmentUrl/.default"

    LogInfo "Acquiring Dataverse token (device code) for $EnvironmentUrl ..."
    $tok = Get-MsalToken -TenantId $TenantId -ClientId $publicClientId -Scopes $scope -DeviceCode
    return $tok.AccessToken
}

function Invoke-DvGetPaged {
    param(
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)][string]$Url
    )

    $headers = @{
        Authorization      = "Bearer $AccessToken"
        Accept             = "application/json"
        "OData-MaxVersion" = "4.0"
        "OData-Version"    = "4.0"
    }

    $results = New-Object System.Collections.ArrayList
    $next = $Url

    while ($next) {
        $resp = Invoke-RestMethod -Method GET -Uri $next -Headers $headers
        if ($resp.value) { 
            foreach ($item in $resp.value) {
                [void]$results.Add($item)
            }
        }
        if ($resp.PSObject.Properties.Name -contains '@odata.nextLink') {
            $next = $resp.'@odata.nextLink'
        } else {
            $next = $null
        }
    }

    return $results.ToArray()
}

function Get-BotTextAttributes {
    param(
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)][string]$ApiBase
    )

    $metaUrl = "$ApiBase/EntityDefinitions(LogicalName='bot')/Attributes?`$select=LogicalName,AttributeType"
    LogInfo "Reading bot table metadata..."
    $attrs = Invoke-DvGetPaged -AccessToken $AccessToken -Url $metaUrl

    $textTypes = @("String","Memo")
    $textAttrs = $attrs | Where-Object { $textTypes -contains $_.AttributeType } | Select-Object -ExpandProperty LogicalName

    $blacklistExact = @(
        "createdbyname","modifiedbyname","owningusername","owningteamname",
        "createdonbehalfbyname","modifiedonbehalfbyname"
    )

    $filteredAttrs = $textAttrs | Where-Object {
        ($_ -notin $blacklistExact) -and
        ($_ -notmatch 'name$' -or $_ -in @("name","schemaname"))
    }

    $mandatory = @("botid","name","schemaname")
    $allAttrs = New-Object System.Collections.ArrayList
    
    foreach ($m in $mandatory) { [void]$allAttrs.Add($m) }
    foreach ($attr in $filteredAttrs) {
        if ($attr -notin $mandatory) { [void]$allAttrs.Add($attr) }
    }

    LogInfo "Discovered $($allAttrs.Count) text fields"
    LogVerbose "Fields: $($allAttrs -join ', ')"
    
    return $allAttrs.ToArray()
}

# ===============================
# MAIN EXECUTION
# ===============================

LogInfo "=== Starting Copilot Studio Agent Search ==="
LogInfo "Entra Agent ID: $EntraAgentObjectId"
LogInfo "Environment URL: $EnvironmentUrl"

$token = Get-DataverseToken -TenantId $TenantId -EnvironmentUrl $EnvironmentUrl
$apiBase = "$EnvironmentUrl/api/data/v9.2"

$textAttrs = Get-BotTextAttributes -AccessToken $token -ApiBase $apiBase

# Create search variants
$searchVariants = @(
    $EntraAgentObjectId.ToLower(),
    $EntraAgentObjectId.ToUpper(),
    $EntraAgentObjectId.Replace("-", "").ToLower(),
    $EntraAgentObjectId.Replace("-", "").ToUpper()
) | Select-Object -Unique

LogInfo "Search variants: $($searchVariants -join ', ')"

# Fetch ALL bots with ALL text fields
$selectFields = $textAttrs -join ","
$url = "$apiBase/bots?`$select=$selectFields&`$top=5000"

LogInfo "Fetching all bot records with all text fields..."
$bots = Invoke-DvGetPaged -AccessToken $token -Url $url
LogInfo "Retrieved $($bots.Count) bot record(s)"

# Search through ALL bots and ALL fields
$found = New-Object System.Collections.ArrayList

foreach ($bot in $bots) {
    $botName = if ($bot.PSObject.Properties.Name -contains "name") { $bot.name } else { "<unnamed>" }
    $schemaName = if ($bot.PSObject.Properties.Name -contains "schemaname") { $bot.schemaname } else { "<no schema>" }
    
    LogVerbose "Scanning bot: $botName (schema: $schemaName)"
    
    foreach ($field in $textAttrs) {
        if (-not ($bot.PSObject.Properties.Name -contains $field)) { 
            continue 
        }

        $val = $bot.$field
        if ($null -eq $val) { 
            continue 
        }

        $text = if ($val -is [string]) { $val } else { ($val | Out-String) }
        
        # Try all search variants
        foreach ($variant in $searchVariants) {
            if ($text -match [regex]::Escape($variant)) {
                LogInfo "*** MATCH FOUND ***"
                LogInfo "  Bot Name: $botName"
                LogInfo "  Schema: $schemaName"
                LogInfo "  Field: $field"
                LogInfo "  Variant: $variant"
                
                if ($VerboseLogging -and $text.Length -le 500) {
                    LogVerbose "  Field content: $text"
                } elseif ($VerboseLogging) {
                    LogVerbose "  Field content (first 500 chars): $($text.Substring(0, 500))..."
                }
                
                $botId = if ($bot.PSObject.Properties.Name -contains "botid") { $bot.botid } else { "<missing>" }
                
                [void]$found.Add([pscustomobject]@{
                    AgentName  = $botName
                    SchemaName = $schemaName
                    BotId      = $botId
                    FoundIn    = $field
                })
                break
            }
        }
        
        if ($found.Count -gt 0) { break }
    }
    
    if ($found.Count -gt 0) { break }
}

# Display results
if ($found.Count -eq 0) {
    LogWarn "No Copilot Studio agent found containing Entra Agent ID: $EntraAgentObjectId"
    LogInfo ""
    LogInfo "Troubleshooting suggestions:"
    LogInfo "1. Verify the Entra Agent ID is correct in Copilot Studio Settings > Advanced"
    LogInfo "2. The GUID might be stored in a non-text field (e.g., Lookup, GUID type)"
    LogInfo "3. Try searching in the Copilot Studio portal directly"
} else {
    LogInfo ""
    LogInfo "================================"
    LogInfo "MATCH(ES) FOUND"
    LogInfo "================================"
    
    foreach ($match in $found) {
        Write-Host ""
        Write-Host "Agent Name  : $($match.AgentName)" -ForegroundColor Green
        Write-Host "Schema Name : $($match.SchemaName)" -ForegroundColor Green
        Write-Host "Bot ID      : $($match.BotId)" -ForegroundColor Green
        Write-Host "Found In    : $($match.FoundIn)" -ForegroundColor Green
        Write-Host "--------------------------------"
    }
}
