Connect-MgGraph -Scopes "AgentIdentityBlueprint.AddRemoveCreds.All"

$applicationId = "<agent-blueprint-app-id>"

# Define the secret properties
$displayName = "<Secret Name>"
$endDate = (Get-Date).AddYears(1).ToString("o")  # 1 year from now, in ISO 8601 format

# Construct the password credential
$passwordCredential = @{
    displayName = $displayName
    endDateTime = $endDate
}

# Add the password (client secret)
$response = Add-MgApplicationPassword -ApplicationId $applicationId -PasswordCredential $passwordCredential

# Output the generated secret (only returned once!)
Write-Host "Secret Text: $($response.secretText)"

# Close the Graph
Disconnect-MgGraph