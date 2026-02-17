# Connect to Microsoft Graph
Connect-MgGraph -Scopes "User.ReadWrite.All"

# Create the body
$body = @{
    "@odata.type" = "microsoft.graph.agentUser"
    displayName = "<Agent User Name>"
    userPrincipalName = "<Agent User UPN>"
    identityParentId = "<Agent-Identity-ID>"
    mailNickname = "<Agent User mailNickname / Alias>"
    accountEnabled = $true
}

# Make the request
$response = Invoke-MgGraphRequest `
    -Method POST `
    -Uri "https://graph.microsoft.com/beta/users" `
    -Body ($body | ConvertTo-Json) `
    -ContentType "application/json" `
    -Headers @{ "OData-Version" = "4.0" }

# Display result
Write-Host "✓ Agent User created successfully!" -ForegroundColor Green
$response

# Close the Graph
Disconnect-MgGraph