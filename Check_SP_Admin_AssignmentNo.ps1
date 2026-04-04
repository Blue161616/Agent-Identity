# Requires Microsoft.Graph
# Install-Module Microsoft.Graph -Scope CurrentUser

Import-Module Microsoft.Graph.Applications

if (-not (Get-MgContext)) {
    Connect-MgGraph -Scopes "Application.Read.All","DelegatedPermissionGrant.Read.All","AppRoleAssignment.ReadWrite.All","Directory.Read.All"
}

Write-Host "Reading all service principals [exclude Microsoft 1st party] and filtering locally for Assignment required = No ..." -ForegroundColor Cyan

# Fallback approach: retrieve all and filter locally
$servicePrincipals = Get-MgServicePrincipal -All `
    -Property "id,appId,displayName,appRoleAssignmentRequired,accountEnabled,publisherName,appOwnerOrganizationId" |
    Where-Object {
        $_.AppRoleAssignmentRequired -eq $false -and
        $_.AccountEnabled -eq $true -and
        $_.PublisherName -notmatch "Microsoft" -and
        $_.AppOwnerOrganizationId -ne "f8cdef31-a31e-4b4a-93e4-5f571e91255a"  # Microsoft tenant
    }
# Cache for resource service principals so permission names can be resolved
$resourceSpCache = @{}

function Get-ResourceServicePrincipal {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceServicePrincipalId
    )

    if (-not $resourceSpCache.ContainsKey($ResourceServicePrincipalId)) {
        try {
            $resourceSpCache[$ResourceServicePrincipalId] = Get-MgServicePrincipal `
                -ServicePrincipalId $ResourceServicePrincipalId `
                -Property "id,appId,displayName,appRoles,oauth2PermissionScopes"
        }
        catch {
            $resourceSpCache[$ResourceServicePrincipalId] = $null
        }
    }

    $resourceSpCache[$ResourceServicePrincipalId]
}

$results = foreach ($sp in $servicePrincipals) {
    Write-Host "Processing: $($sp.DisplayName)" -ForegroundColor DarkGray

    # Delegated permissions with admin consent
    $delegatedGrants = @()
    try {
        $delegatedGrants = Get-MgServicePrincipalOauth2PermissionGrant -ServicePrincipalId $sp.Id -All |
            Where-Object { $_.ConsentType -eq "AllPrincipals" }
    }
    catch {
        Write-Warning "Could not read delegated grants for $($sp.DisplayName): $($_.Exception.Message)"
    }

    # Application permissions
    $appRoleAssignments = @()
    try {
        $appRoleAssignments = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id -All
    }
    catch {
        Write-Warning "Could not read app role assignments for $($sp.DisplayName): $($_.Exception.Message)"
    }

    if (($delegatedGrants.Count -eq 0) -and ($appRoleAssignments.Count -eq 0)) {
        continue
    }

    foreach ($grant in $delegatedGrants) {
        $resourceSp = Get-ResourceServicePrincipal -ResourceServicePrincipalId $grant.ResourceId

        [pscustomobject]@{
            EnterpriseAppName     = $sp.DisplayName
            EnterpriseAppObjectId = $sp.Id
            EnterpriseAppAppId    = $sp.AppId
            AccountEnabled        = $sp.AccountEnabled
            AssignmentRequired    = $sp.AppRoleAssignmentRequired
            PermissionType        = "Delegated (Admin Consent)"
            ResourceApiName       = if ($resourceSp) { $resourceSp.DisplayName } else { $grant.ResourceId }
            ResourceApiObjectId   = $grant.ResourceId
            PermissionName        = $grant.Scope
            PermissionId          = $null
            ConsentType           = $grant.ConsentType
            GrantId               = $grant.Id
        }
    }

    foreach ($assignment in $appRoleAssignments) {
        $resourceSp = Get-ResourceServicePrincipal -ResourceServicePrincipalId $assignment.ResourceId

        $appRoleValue = $null
        $appRoleDisplayName = $null

        if ($resourceSp -and $resourceSp.AppRoles) {
            $matchedRole = $resourceSp.AppRoles | Where-Object { $_.Id -eq $assignment.AppRoleId }
            if ($matchedRole) {
                $appRoleValue = $matchedRole.Value
                $appRoleDisplayName = $matchedRole.DisplayName
            }
        }

        [pscustomobject]@{
            EnterpriseAppName     = $sp.DisplayName
            EnterpriseAppObjectId = $sp.Id
            EnterpriseAppAppId    = $sp.AppId
            AccountEnabled        = $sp.AccountEnabled
            AssignmentRequired    = $sp.AppRoleAssignmentRequired
            PermissionType        = "Application"
            ResourceApiName       = if ($resourceSp) { $resourceSp.DisplayName } else { $assignment.ResourceId }
            ResourceApiObjectId   = $assignment.ResourceId
            PermissionName        = if ($appRoleValue) { $appRoleValue } else { $appRoleDisplayName }
            PermissionId          = $assignment.AppRoleId
            ConsentType           = "N/A"
            GrantId               = $assignment.Id
        }
    }
}

$results = $results | Sort-Object EnterpriseAppName, PermissionType, ResourceApiName, PermissionName

$results | Format-Table -AutoSize

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$csvPath = ".\EnterpriseApps_AdminConsent_AssignmentRequiredNo_$timestamp.csv"
$results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

Write-Host "`nExported to: $csvPath" -ForegroundColor Green
$results