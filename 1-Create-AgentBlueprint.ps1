# Connect Graph with required scopes
Connect-MgGraph -Scopes "AgentIdentityBlueprint.Create"

# Define these variables
$BlueprintDisplayName = "<Agent Blueprint Name>"
$SponsorUserId = "<Sponsor-UserID>"  # Replace with actual user ID
$OwnerUserId = "<Owner-UserID>"     # Replace with actual user ID

# Construct the body for the POST request
$body = @{
    "@odata.type" = "Microsoft.Graph.AgentIdentityBlueprint"
    "displayName" = $BlueprintDisplayName
    "sponsors@odata.bind" = @("https://graph.microsoft.com/beta/users/$SponsorUserId")
    "owners@odata.bind" = @("https://graph.microsoft.com/beta/users/$OwnerUserId")
} | ConvertTo-Json -Depth 5

# Make the POST request to create the agent identity blueprint application
$blueprint = Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/beta/applications/graph.agentIdentityBlueprint" -Body $body -ContentType "application/json"

# Output the response
$blueprint

# Close the Graph
Disconnect-MgGraph