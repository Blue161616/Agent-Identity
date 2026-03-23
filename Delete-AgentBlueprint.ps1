Connect-MgGraph -Scopes @(
    "AgentIdentityBlueprint.ReadWrite.All",
    "AgentIdentityBlueprint.DeleteRestore.All"
) -TenantId "<your-tenant-id>"

$BlueprintAppId = "<blueprint-app-id>"
$SPObjectId     = "<sp-object-id>"

# Get application object ID
$app         = Invoke-MgGraphRequest `
    -Method GET `
    -Uri "https://graph.microsoft.com/beta/applications?`$filter=appId eq '$BlueprintAppId'" `
    -Headers @{ "OData-Version" = "4.0" }
$AppObjectId = $app.value[0].id
Write-Output "App Object ID: $AppObjectId"

# Step 1: Delete Blueprint Principal using type cast endpoint
Invoke-MgGraphRequest `
    -Method DELETE `
    -Uri "https://graph.microsoft.com/beta/servicePrincipals/$SPObjectId/microsoft.graph.agentIdentityBlueprintPrincipal" `
    -Headers @{ "OData-Version" = "4.0" }
Write-Output "Blueprint Principal deleted."

# Step 2: Soft-delete the Blueprint
Invoke-MgGraphRequest `
    -Method DELETE `
    -Uri "https://graph.microsoft.com/beta/applications/$AppObjectId/microsoft.graph.agentIdentityBlueprint" `
    -Headers @{ "OData-Version" = "4.0" }
Write-Output "Blueprint soft-deleted."

# Step 3: Permanently delete
Invoke-MgGraphRequest `
    -Method DELETE `
    -Uri "https://graph.microsoft.com/beta/directory/deletedItems/$AppObjectId" `
    -Headers @{ "OData-Version" = "4.0" }
Write-Output "Blueprint permanently deleted."

Disconnect-MgGraph