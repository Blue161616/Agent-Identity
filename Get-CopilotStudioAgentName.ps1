<#
Get Copilot Studio Agent Name from Copilot "Agent app ID" (Entra appId / clientId)

Usage:
  .\Get-CopilotStudioAgentName.ps1 -AgentAppId "1c20bce1-bbac-4468-8b1c-0e4541b5e126"
#>

param(
  [Parameter(Mandatory=$true)]
  [string]$AgentAppId
)

# Requires: Microsoft.Graph module
# Permissions: Application.Read.All (or Directory.Read.All)
if (-not (Get-MgContext)) {
  Connect-MgGraph -Scopes "Application.Read.All"
}

# 1) Find service principal by appId (clientId)
$sp = Get-MgServicePrincipal -Filter "appId eq '$AgentAppId'" -ConsistencyLevel eventual -CountVariable c -All

if (-not $sp) {
  throw "No Service Principal found with appId (clientId) '$AgentAppId'. Verify you're in the right tenant and the agent has been created/published."
}

if ($sp.Count -gt 1) {
  Write-Warning "Found multiple service principals with the same appId. Returning all matches."
}

# 2) Output what you need
$sp | Select-Object `
  @{n="CopilotStudioAgentName";e={$_.DisplayName}}, `
  @{n="ServicePrincipalObjectId";e={$_.Id}}, `
  @{n="AgentAppId(ClientId)";e={$_.AppId}}, `
  PublisherName, ServicePrincipalType, AccountEnabled
