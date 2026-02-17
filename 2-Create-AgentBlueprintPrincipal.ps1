Connect-MgGraph -Scopes "AgentIdentityBlueprintPrincipal.Create"
$body = @{
    appId   = "<agent-blueprint-app-id>"
}
Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/beta/serviceprincipals/graph.agentIdentityBlueprintPrincipal" -Headers @{ "OData-Version" = "4.0" } -Body ($body | ConvertTo-Json)

# Close the Graph
Disconnect-MgGraph