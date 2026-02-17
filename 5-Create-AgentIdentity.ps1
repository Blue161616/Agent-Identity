Connect-MgGraph -Scopes "AgentIdentity.Create.All"

$tenantId = "<tenant-ID>"
$AppId = "<agent-blueprint-app-id>"
$clientSecret = "<secret>"
$sponsorId = "<Sponsor-UserID>" 
$agentIdName = "<Agent Name>" 

# Token endpoint
$tokenUrl = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"

# Create the request body
$body = @{
    client_id     = $AppId
    client_secret = $clientSecret
    scope         = "https://graph.microsoft.com/.default"
    grant_type    = "client_credentials"
}

# Get the access token
$response = Invoke-RestMethod -Method POST -Uri $tokenUrl -Body $body -ContentType "application/x-www-form-urlencoded"

$accessToken = $response.access_token

# Use the token to call Microsoft Graph
$headers = @{
    "Authorization" = "Bearer $accessToken"
    "Content-Type"  = "application/json"
}

$SecuredPasswordPassword = ConvertTo-SecureString `
-String $clientSecret -AsPlainText -Force

$ClientSecretCredential = New-Object `
-TypeName System.Management.Automation.PSCredential `
-ArgumentList $AppId, $SecuredPasswordPassword

Connect-MgGraph -TenantId $tenantID -ClientSecretCredential $ClientSecretCredential

$uri = "/beta/servicePrincipals/microsoft.graph.agentIdentity"
$body = @{
  displayName = $agentIdName
  agentIdentityBlueprintId = $AppId
  "sponsors@odata.bind" = @(
    "https://graph.microsoft.com/v1.0/users/$sponsorId"
  )
}

Invoke-MgGraphRequest -Method Post -Uri $uri -Body $body -OutputType PSObject

# Close the Graph
Disconnect-MgGraph