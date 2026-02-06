<# 
Get-CopilotStudioAgentCreatorByName.ps1
Finds Dataverse Bot(s) by name and returns CreatedBy (maker).
#>

Import-Module MSAL.PS

$EnvironmentUrl = Read-Host "Enter Dataverse Environment URL (e.g. https://blue16.crm4.dynamics.com)"
$BotNameQuery   = Read-Host "Enter Copilot Studio agent name (supports partial match)"
$TenantId       = Read-Host "Enter Tenant ID (optional - press Enter to skip)"

if ($EnvironmentUrl -notmatch '^https://.+$') { throw "Invalid EnvironmentUrl" }
if ([string]::IsNullOrWhiteSpace($BotNameQuery)) { throw "Bot name is required" }

$EnvironmentUrl = $EnvironmentUrl.TrimEnd('/')

# Dataverse scope
$scope = "$EnvironmentUrl/.default"

# Public client id (Azure PowerShell)
$clientId = "1950a258-227b-4e31-a9cf-717495945fc2"

# Acquire token (Device Code)
if ([string]::IsNullOrWhiteSpace($TenantId)) {
    $msal = Get-MsalToken -ClientId $clientId -Scopes $scope -DeviceCode
} else {
    $msal = Get-MsalToken -ClientId $clientId -TenantId $TenantId -Scopes $scope -DeviceCode
}
$token = $msal.AccessToken

$headers = @{
  Authorization      = "Bearer $token"
  "OData-MaxVersion" = "4.0"
  "OData-Version"    = "4.0"
  Accept             = "application/json"
}

# Escape single quotes for OData
$escaped = $BotNameQuery.Replace("'", "''")

# Use contains() so partial matches work (e.g. "Agent Identity Blog 03")
$uri = "$EnvironmentUrl/api/data/v9.2/bots?" +
       "`$select=botid,name,createdon,_createdby_value,origin&" +
       "`$filter=contains(name,'$escaped')&" +
       "`$expand=createdby(`$select=fullname,domainname,internalemailaddress,systemuserid)"

$response = Invoke-RestMethod -Method GET -Uri $uri -Headers $headers

if (-not $response.value -or $response.value.Count -eq 0) {
  Write-Warning "No bots found matching name '$BotNameQuery' in $EnvironmentUrl (or no read access)."
  return
}

$response.value |
  Sort-Object createdon -Descending |
  ForEach-Object {
    [pscustomobject]@{
      BotName       = $_.name
      BotId         = $_.botid
      Origin        = $_.origin
      CreatedOn     = $_.createdon
      CreatedByName = $_.createdby.fullname
      CreatedByUPN  = $_.createdby.domainname
      CreatedByMail = $_.createdby.internalemailaddress
      CreatedById   = $_.createdby.systemuserid
    }
  } | Format-Table -AutoSize
