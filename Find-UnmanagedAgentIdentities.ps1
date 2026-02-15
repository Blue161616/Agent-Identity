<#
.SYNOPSIS
    Finds unmanaged Agent Identities with an Agent Blueprint.

.DESCRIPTION
    This script identifies modern Agent Identities (those with an Agent Identity Blueprint)
    that have no owners or sponsors assigned. These are "unmanaged" agents that lack
    proper governance and oversight.
    
    Version: 1.1 (Fixed - API call issue resolved)

.PARAMETER OutputPath
    Optional path to export results to a CSV file.

.PARAMETER IncludeDetails
    Switch to include additional details about each agent identity.

.EXAMPLE
    .\Find-UnmanagedAgentIdentities.ps1
    Displays unmanaged agent identities in the console.

.EXAMPLE
    .\Find-UnmanagedAgentIdentities.ps1 -OutputPath "C:\Reports\UnmanagedAgents.csv"
    Exports results to a CSV file.

.EXAMPLE
    .\Find-UnmanagedAgentIdentities.ps1 -IncludeDetails
    Shows additional details including creation date and blueprint information.

.NOTES
    Author: Generated Script
    Requires: Microsoft.Graph PowerShell module (beta)
    Required Permissions: AgentIdentity.Read.All or Application.Read.All
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$OutputPath,
    
    [Parameter(Mandatory=$false)]
    [switch]$IncludeDetails
)

#Requires -Modules Microsoft.Graph.Beta.Applications

# Function to check if user is connected to Microsoft Graph
function Test-GraphConnection {
    try {
        $context = Get-MgContext
        if ($null -eq $context) {
            return $false
        }
        return $true
    }
    catch {
        return $false
    }
}

# Function to connect to Microsoft Graph
function Connect-ToGraph {
    Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
    
    $requiredScopes = @(
        "AgentIdentity.Read.All"
    )
    
    try {
        Connect-MgGraph -Scopes $requiredScopes -NoWelcome -ErrorAction Stop
        Write-Host "Successfully connected to Microsoft Graph." -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to connect to Microsoft Graph: $_"
        exit 1
    }
}

# Main script execution
Write-Host "`n=== Finding Unmanaged Agent Identities ===" -ForegroundColor Cyan
Write-Host "This script will identify Agent Identities with blueprints that have no owners or sponsors.`n" -ForegroundColor Yellow

# Check and establish connection
if (-not (Test-GraphConnection)) {
    Connect-ToGraph
}
else {
    Write-Host "Already connected to Microsoft Graph." -ForegroundColor Green
}

# Retrieve all Agent Identities with blueprints
Write-Host "`nRetrieving Agent Identities..." -ForegroundColor Cyan

try {
    # Get all agent identities (Note: Graph API doesn't support expanding both owners and sponsors in one call)
    if ($IncludeDetails) {
        $uri = "https://graph.microsoft.com/beta/servicePrincipals/microsoft.graph.agentIdentity?`$select=id,displayName,agentIdentityBlueprintId,createdDateTime,accountEnabled,servicePrincipalType"
    }
    else {
        $uri = "https://graph.microsoft.com/beta/servicePrincipals/microsoft.graph.agentIdentity?`$select=id,displayName,agentIdentityBlueprintId"
    }
    
    $allAgents = @()
    
    do {
        $response = Invoke-MgGraphRequest -Method GET -Uri $uri
        $allAgents += $response.value
        $uri = $response.'@odata.nextLink'
    } while ($uri)
    
    Write-Host "Found $($allAgents.Count) total Agent Identities." -ForegroundColor Green
    
    # Now get owners and sponsors for each agent
    Write-Host "Retrieving ownership and sponsorship information..." -ForegroundColor Cyan
    
    $progressCount = 0
    foreach ($agent in $allAgents) {
        $progressCount++
        if ($progressCount % 10 -eq 0) {
            Write-Host "  Processing $progressCount of $($allAgents.Count)..." -ForegroundColor Gray
        }
        
        # Get owners
        try {
            $ownersUri = "https://graph.microsoft.com/beta/servicePrincipals/$($agent.id)/owners"
            $ownersResponse = Invoke-MgGraphRequest -Method GET -Uri $ownersUri
            $agent | Add-Member -NotePropertyName "owners" -NotePropertyValue $ownersResponse.value -Force
        }
        catch {
            $agent | Add-Member -NotePropertyName "owners" -NotePropertyValue @() -Force
        }
        
        # Get sponsors
        try {
            $sponsorsUri = "https://graph.microsoft.com/beta/servicePrincipals/$($agent.id)/microsoft.graph.agentIdentity/sponsors"
            $sponsorsResponse = Invoke-MgGraphRequest -Method GET -Uri $sponsorsUri
            $agent | Add-Member -NotePropertyName "sponsors" -NotePropertyValue $sponsorsResponse.value -Force
        }
        catch {
            $agent | Add-Member -NotePropertyName "sponsors" -NotePropertyValue @() -Force
        }
    }
    
    Write-Host "Ownership information retrieved." -ForegroundColor Green
    
    # Filter for agents with blueprints (modern agents)
    $agentsWithBlueprints = $allAgents | Where-Object { 
        $null -ne $_.agentIdentityBlueprintId -and 
        $_.agentIdentityBlueprintId -ne "" 
    }
    
    Write-Host "Found $($agentsWithBlueprints.Count) Agent Identities with blueprints." -ForegroundColor Green
    
    # Filter for unmanaged agents (no owners or sponsors)
    $unmanagedAgents = $agentsWithBlueprints | Where-Object {
        ($null -eq $_.owners -or $_.owners.Count -eq 0) -and
        ($null -eq $_.sponsors -or $_.sponsors.Count -eq 0)
    }
    
    Write-Host "`nFound $($unmanagedAgents.Count) unmanaged Agent Identities with blueprints.`n" -ForegroundColor Yellow
    
    # Display results
    if ($unmanagedAgents.Count -eq 0) {
        Write-Host "No unmanaged Agent Identities found. All agents with blueprints have owners or sponsors!" -ForegroundColor Green
    }
    else {
        # Prepare output data
        $results = @()
        
        foreach ($agent in $unmanagedAgents) {
            $result = [PSCustomObject]@{
                DisplayName = $agent.displayName
                ObjectId = $agent.id
                BlueprintId = $agent.agentIdentityBlueprintId
            }
            
            if ($IncludeDetails) {
                $result | Add-Member -NotePropertyName CreatedDateTime -NotePropertyValue $agent.createdDateTime
                $result | Add-Member -NotePropertyName AccountEnabled -NotePropertyValue $agent.accountEnabled
                $result | Add-Member -NotePropertyName ServicePrincipalType -NotePropertyValue $agent.servicePrincipalType
            }
            
            $results += $result
        }
        
        # Display in console
        Write-Host "Unmanaged Agent Identities:" -ForegroundColor Yellow
        $results | Format-Table -AutoSize
        
        # Export to CSV if requested
        if ($OutputPath) {
            try {
                $results | Export-Csv -Path $OutputPath -NoTypeInformation -Force
                Write-Host "`nResults exported to: $OutputPath" -ForegroundColor Green
            }
            catch {
                Write-Error "Failed to export results: $_"
            }
        }
        
        # Summary
        Write-Host "`n=== Summary ===" -ForegroundColor Cyan
        Write-Host "Total Agent Identities: $($allAgents.Count)" -ForegroundColor White
        Write-Host "Agent Identities with Blueprints: $($agentsWithBlueprints.Count)" -ForegroundColor White
        Write-Host "Unmanaged Agent Identities: $($unmanagedAgents.Count)" -ForegroundColor Yellow
        Write-Host "`nRecommendation: Assign owners or sponsors to these agent identities for proper governance." -ForegroundColor Yellow
    }
}
catch {
    Write-Error "An error occurred while retrieving agent identities: $_"
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

Write-Host "`nScript completed." -ForegroundColor Green
