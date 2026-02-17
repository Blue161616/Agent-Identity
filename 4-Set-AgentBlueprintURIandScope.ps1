Connect-MgGraph -Scopes "AgentIdentityBlueprint.ReadWrite.All"

$AppId = "<agent-blueprint-app-id>"
$IdentifierUri = "api://$AppId"
$ScopeId = [guid]::NewGuid()

$body = @{
    identifierUris = @($IdentifierUri)
    api = @{
        oauth2PermissionScopes = @(
            @{
                adminConsentDescription = "Allow the application to access the agent on behalf of the signed-in user."
                adminConsentDisplayName = "Access agent"
                id = $ScopeId.ToString()
                isEnabled = $true
                type = "User"
                value = "access_agent"
            }
        )
    }
} | ConvertTo-Json -Depth 10

# Use BETA endpoint
$uri = "https://graph.microsoft.com/beta/applications/$AppId"

Invoke-MgGraphRequest -Method PATCH -Uri $uri -Body $body -ContentType "application/json"

# Close the Graph
Disconnect-MgGraph