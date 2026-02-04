<#
.SYNOPSIS
  Find Copilot Studio agent name by Entra Agent ID (GUID) by scanning ALL text fields of Dataverse bot table.

.EXAMPLE
  .\Get-CopilotStudioAgentName.ps1 `
    -EntraAgentObjectId "<Entra-Agent-Object-ID>" `
    -EnvironmentUrl "https://<PowerPlatformEnvironment>.crm4.dynamics.com"
    -TenantId "Tenant-Id"
#>

param(
    [Parameter(Mandatory=$false)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string] $EntraAgentObjectId,

    [Parameter(Mandatory)]
    [ValidatePattern('^https://.+$')]
    [string] $EnvironmentUrl,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string] $TenantId,

    # How many attributes to fetch per request (avoids overly long URLs)
    [Parameter()]
    [ValidateRange(5,60)]
    [int] $AttributeChunkSize = 25
)

if ([string]::IsNullOrWhiteSpace($EntraAgentObjectId)) {
    $EntraAgentObjectId = Read-Host "Enter Entra Agent Identity Object ID (GUID)"
}

if ($EntraAgentObjectId -notmatch '^[0-9a-fA-F-]{36}$') {
    throw "Invalid GUID format for EntraAgentObjectId: '$EntraAgentObjectId'"
}


Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function LogInfo($msg) { Write-Host ("[{0}] [Info] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg) }
function LogWarn($msg) { Write-Host ("[{0}] [Warn] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg) -ForegroundColor Yellow }
function LogErr ($msg) { Write-Host ("[{0}] [Error] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg) -ForegroundColor Red }

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

    # Public client (Azure CLI). If blocked in your tenant, replace with your own app registration.
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

    $all  = New-Object System.Collections.Generic.List[object]
    $next = $Url

    while ($next) {
        $resp = Invoke-RestMethod -Method GET -Uri $next -Headers $headers

        if ($resp.value) { $resp.value | ForEach-Object { $all.Add($_) } }

        if ($resp.PSObject.Properties.Name -contains '@odata.nextLink') {
            $next = $resp.'@odata.nextLink'
        } else {
            $next = $null
        }
    }

    return $all
}

function Get-BotTextAttributes {
    param(
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)][string]$ApiBase
    )

    $metaUrl = "$ApiBase/EntityDefinitions(LogicalName='bot')/Attributes?`$select=LogicalName,AttributeType"

    LogInfo "Reading bot table metadata to discover text fields..."
    $attrs = Invoke-DvGetPaged -AccessToken $AccessToken -Url $metaUrl

    $textTypes = @("String","Memo")
    $textAttrs = $attrs |
        Where-Object { $textTypes -contains $_.AttributeType } |
        Select-Object -ExpandProperty LogicalName

    # Remove common non-selectable / pseudo fields if they somehow appear
    $blacklistExact = @(
        "createdbyname","modifiedbyname","owningusername","owningteamname",
        "createdonbehalfbyname","modifiedonbehalfbyname"
    )

    $textAttrs = $textAttrs |
        Where-Object {
            ($_ -notin $blacklistExact) -and
            ($_ -notmatch 'name$' -or $_ -in @("name","schemaname")) # keep real name columns
        }

    # Always include core fields
    $mandatory = @("botid","name","schemaname")
    $textAttrs = ($mandatory + ($textAttrs | Where-Object { $mandatory -notcontains $_ })) | Select-Object -Unique

    LogInfo ("Discovered {0} selectable text fields on bot table." -f ($textAttrs.Count))
    return ,$textAttrs
}


function Chunk-Array {
    param(
        [Parameter(Mandatory)][object[]]$Items,
        [Parameter(Mandatory)][int]$Size
    )

    for ($i = 0; $i -lt $Items.Count; $i += $Size) {
        $Items[$i..([Math]::Min($i + $Size - 1, $Items.Count - 1))]
    }
}

function Find-AgentByGuidAcrossBotTextFields {
    param(
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)][string]$ApiBase,
        [Parameter(Mandatory)][string]$GuidText,
        [Parameter(Mandatory)][string[]]$TextAttributes,
        [Parameter(Mandatory)][int]$ChunkSize
    )

    $found = @()

    # Always fetch these so output never breaks
    $core = @("botid","name","schemaname")

    # Make sure we don't chunk the core fields (they'll be added to every select anyway)
    $scanAttrs = $TextAttributes | Where-Object { $core -notcontains $_ } | Select-Object -Unique

    $chunks = @(Chunk-Array -Items $scanAttrs -Size $ChunkSize)

    for ($chunkIndex = 0; $chunkIndex -lt $chunks.Count; $chunkIndex++) {
        $chunk = @($chunks[$chunkIndex])

        $retry = $true
        while ($retry) {
            $retry = $false

            # Build a safe select list: core + chunk
            $selectFields = @($core + $chunk) | Select-Object -Unique
            $select = ($selectFields -join ",")
            $url = "$ApiBase/bots?`$select=$select&`$top=5000"

            LogInfo ("Fetching bot records (chunk {0}/{1})..." -f ($chunkIndex + 1), $chunks.Count)

            try {
                $bots = Invoke-DvGetPaged -AccessToken $AccessToken -Url $url
            }
            catch {
                $msg = $_.Exception.Message

                # Parse: "Could not find a property named 'X' on type 'Microsoft.Dynamics.CRM.bot'."
                if ($msg -match "Could not find a property named\s+'([^']+)'") {
                    $badField = $Matches[1]
                    LogWarn "Dataverse rejected field '$badField' in `$select. Removing it and retrying this chunk..."

                    # Never remove the core fields
                    if ($core -contains $badField) {
                        throw "Dataverse rejected required core field '$badField'. Something is off with the bot entity schema."
                    }

                    $chunk = $chunk | Where-Object { $_ -ne $badField }

                    # Re-run same chunk without the bad field
                    $retry = $true
                    continue
                }

                throw
            }

            foreach ($b in $bots) {

                foreach ($field in $chunk) {
                    if (-not ($b.PSObject.Properties.Name -contains $field)) { continue }

                    $val = $b.$field
                    if ($null -eq $val) { continue }

                    $text = if ($val -is [string]) { $val } else { ($val | Out-String) }

                    if ($text -match [regex]::Escape($GuidText)) {
                        # Safe reads (but core fields should always be present now)
                        $agentName  = if ($b.PSObject.Properties.Name -contains "name") { $b.name } else { "<missing>" }
                        $schemaName = if ($b.PSObject.Properties.Name -contains "schemaname") { $b.schemaname } else { "<missing>" }
                        $botId      = if ($b.PSObject.Properties.Name -contains "botid") { $b.botid } else { "<missing>" }

                        $found += [pscustomobject]@{
                            AgentName  = $agentName
                            SchemaName = $schemaName
                            BotId      = $botId
                            FoundIn    = $field
                        }
                        break
                    }
                }

                if ($found.Count -gt 0) { break }
            }

            if ($found.Count -gt 0) { break }
        }

        if ($found.Count -gt 0) { break }
    }

    return $found
}



# ---- MAIN ----
LogInfo "=== Starting Copilot Studio Agent Name Retrieval ==="
LogInfo "Entra Agent ID: $EntraAgentObjectId"
LogInfo "Environment URL: $EnvironmentUrl"

$token  = Get-DataverseToken -TenantId $TenantId -EnvironmentUrl $EnvironmentUrl
$apiBase = "$EnvironmentUrl/api/data/v9.2"

$textAttrs = Get-BotTextAttributes -AccessToken $token -ApiBase $apiBase

$matches = Find-AgentByGuidAcrossBotTextFields `
    -AccessToken $token `
    -ApiBase $apiBase `
    -GuidText $EntraAgentObjectId `
    -TextAttributes $textAttrs `
    -ChunkSize $AttributeChunkSize

if (-not $matches -or $matches.Count -eq 0) {
    LogWarn "No Copilot Studio agent found containing Entra Agent ID: $EntraAgentObjectId"
    LogInfo "=== Completed ==="
    return
}

LogInfo "Match(es) found:"
$matches | Sort-Object AgentName | Format-Table -AutoSize
LogInfo "=== Completed ==="




