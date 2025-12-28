#region Pilot Deployment Script - Delta Architecture
<#
.SYNOPSIS
    Deploys Entra Risk Analysis infrastructure with delta change detection
.DESCRIPTION
    Simplified deployment for pilot with:
    - Blob Storage (7-day retention, landing zone)
    - Cosmos DB (3 containers: users_raw, user_changes, snapshots)
    - Function App with delta detection enabled
    - AI Foundry Hub and Project
    - All optimizations included
    
    Cost: $1-3/month for 1GB daily exports
    
.PARAMETER SubscriptionId
    Azure subscription ID
.PARAMETER TenantId
    Entra ID tenant ID
.PARAMETER ResourceGroupName
    Resource group name (default: rg-entrarisk-pilot-001)
.PARAMETER Location
    Azure region (default: eastus)
.PARAMETER Environment
    Environment name (default: dev)
.PARAMETER BlobRetentionDays
    Blob retention in days (default: 7)
.PARAMETER WorkloadName
    Workload name for resources (default: entrarisk)
    
.EXAMPLE
    .\deploy-pilot-delta.ps1 -SubscriptionId "xxx" -TenantId "yyy"
    
.EXAMPLE
    .\deploy-pilot-delta.ps1 -SubscriptionId "xxx" -TenantId "yyy" -BlobRetentionDays 30
#>
#endregion

#Requires -Modules Az.Accounts, Az.Resources

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory=$true)]
    [string]$TenantId,
    
    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupName = "rg-entrarisk-pilot-001",
    
    [Parameter(Mandatory=$false)]
    [string]$Location = "eastus",
    
    [Parameter(Mandatory=$false)]
    [ValidateSet('dev', 'test', 'prod')]
    [string]$Environment = "dev",
    
    [Parameter(Mandatory=$false)]
    [ValidateRange(1, 365)]
    [int]$BlobRetentionDays = 7,
    
    [Parameter(Mandatory=$false)]
    [string]$WorkloadName = "entrarisk"
)

#region Helper Functions
function Write-DeploymentHeader {
    param([string]$Message)
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host $Message -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host ""
}

function Write-DeploymentSuccess {
    param([string]$Message)
    Write-Host "✓ $Message" -ForegroundColor Green
}

function Write-DeploymentInfo {
    param([string]$Label, [string]$Value)
    Write-Host "  ${Label}: " -NoNewline -ForegroundColor Gray
    Write-Host $Value -ForegroundColor White
}
#endregion

#region Banner
Write-DeploymentHeader "Entra Risk Analysis - Delta Architecture Deployment"

Write-Host "Deployment Configuration:" -ForegroundColor Yellow
Write-DeploymentInfo "Subscription" $SubscriptionId
Write-DeploymentInfo "Tenant" $TenantId
Write-DeploymentInfo "Resource Group" $ResourceGroupName
Write-DeploymentInfo "Location" $Location
Write-DeploymentInfo "Environment" $Environment
Write-DeploymentInfo "Blob Retention" "$BlobRetentionDays days"
Write-DeploymentInfo "Architecture" "Delta Change Detection"
Write-Host ""

# Cost estimate
$estimatedCost = if ($BlobRetentionDays -le 7) { 
    "~`$1-2/month" 
} else { 
    "~`$2-3/month" 
}
Write-Host "Estimated Monthly Cost: " -NoNewline -ForegroundColor Gray
Write-Host $estimatedCost -ForegroundColor Green
#endregion

#region Azure Connection
Write-Host ""
Write-Host "Connecting to Azure..." -ForegroundColor Yellow

try {
    $context = Get-AzContext -ErrorAction Stop
    
    if (-not $context -or $context.Subscription.Id -ne $SubscriptionId) {
        Write-Host "Authentication required..."
        Connect-AzAccount -ErrorAction Stop | Out-Null
        Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
    }
    
    $context = Get-AzContext
    Write-DeploymentSuccess "Connected to Azure"
    Write-DeploymentInfo "Account" $context.Account.Id
    Write-DeploymentInfo "Subscription" $context.Subscription.Name
}
catch {
    Write-Error "Failed to connect to Azure: $_"
    exit 1
}
#endregion

#region Resource Group
Write-Host ""
Write-Host "Creating/Verifying resource group..." -ForegroundColor Yellow

try {
    $rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
    
    if (-not $rg) {
        $rg = New-AzResourceGroup -Name $ResourceGroupName -Location $Location -Tag @{
            Environment = $Environment
            Workload = $WorkloadName
            Project = 'EntraRiskAnalysis-Delta'
            DeployedBy = $env:USERNAME
            DeployedDate = (Get-Date -Format 'yyyy-MM-dd')
            Architecture = 'DeltaChangeDetection'
        } -ErrorAction Stop
        
        Write-DeploymentSuccess "Resource group created"
    }
    else {
        Write-DeploymentSuccess "Resource group exists"
    }
    
    Write-DeploymentInfo "Name" $rg.ResourceGroupName
    Write-DeploymentInfo "Location" $rg.Location
}
catch {
    Write-Error "Failed to create resource group: $_"
    exit 1
}
#endregion

#region Bicep Deployment
Write-Host ""
Write-Host "Deploying infrastructure (this may take 5-10 minutes)..." -ForegroundColor Yellow

$bicepFile = Join-Path $PSScriptRoot "main-pilot-delta.bicep"

if (-not (Test-Path $bicepFile)) {
    Write-Error "Bicep file not found: $bicepFile"
    exit 1
}

$deploymentName = "delta-pilot-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

Write-Host "  Deployment name: $deploymentName"
Write-Host "  Template: $(Split-Path $bicepFile -Leaf)"
Write-Host ""

try {
    # Start deployment
    $deployment = New-AzResourceGroupDeployment `
        -Name $deploymentName `
        -ResourceGroupName $ResourceGroupName `
        -TemplateFile $bicepFile `
        -workloadName $WorkloadName `
        -environment $Environment `
        -location $Location `
        -tenantId $TenantId `
        -blobRetentionDays $BlobRetentionDays `
        -Verbose `
        -ErrorAction Stop
    
    Write-DeploymentSuccess "Infrastructure deployment completed"
}
catch {
    Write-Error "Deployment failed: $_"
    Write-Host ""
    Write-Host "Troubleshooting:" -ForegroundColor Yellow
    Write-Host "  1. Check Azure portal for detailed error messages"
    Write-Host "  2. Verify you have Contributor access to subscription"
    Write-Host "  3. Ensure Cosmos DB and AI services are available in region"
    Write-Host "  4. Review deployment logs in Azure DevOps"
    exit 1
}
#endregion

#region Display Results
Write-DeploymentHeader "Deployment Complete!"

Write-Host "Deployed Resources:" -ForegroundColor Cyan
Write-Host ""

# Storage
Write-Host "STORAGE LAYER:" -ForegroundColor Yellow
Write-DeploymentInfo "Storage Account" $deployment.Outputs.storageAccountName.Value
Write-DeploymentInfo "Blob Retention" "$BlobRetentionDays days (auto-delete)"
Write-DeploymentInfo "Purpose" "Landing zone + checkpoint"
Write-Host ""

# Cosmos DB
Write-Host "COSMOS DB LAYER:" -ForegroundColor Yellow
Write-DeploymentInfo "Account" $deployment.Outputs.cosmosDbAccountName.Value
Write-DeploymentInfo "Endpoint" $deployment.Outputs.cosmosDbEndpoint.Value
Write-DeploymentInfo "Database" $deployment.Outputs.cosmosDatabaseName.Value
Write-Host ""
Write-Host "  Containers:" -ForegroundColor Gray
Write-Host "    1. $($deployment.Outputs.cosmosContainerUsersRaw.Value) - Current user state"
Write-Host "    2. $($deployment.Outputs.cosmosContainerUserChanges.Value) - Change log (365 day TTL)"
Write-Host "    3. $($deployment.Outputs.cosmosContainerSnapshots.Value) - Collection metadata"
Write-Host ""

# Function App
Write-Host "FUNCTION APP:" -ForegroundColor Yellow
Write-DeploymentInfo "Name" $deployment.Outputs.functionAppName.Value
Write-DeploymentInfo "URL" "https://$($deployment.Outputs.functionAppName.Value).azurewebsites.net"
Write-DeploymentInfo "Plan" "Consumption (Dynamic)"
Write-DeploymentInfo "Features" "Delta detection enabled"
Write-Host ""

# AI Foundry
Write-Host "AI FOUNDRY:" -ForegroundColor Yellow
Write-DeploymentInfo "Hub" ($deployment.Outputs.aiFoundryHubName.Value ?? "N/A")
Write-DeploymentInfo "Project" ($deployment.Outputs.aiFoundryProjectName.Value ?? "N/A")
Write-Host ""

# Monitoring
Write-Host "MONITORING:" -ForegroundColor Yellow
Write-DeploymentInfo "Application Insights" $deployment.Outputs.appInsightsName.Value
Write-Host ""

# Identity
Write-Host "MANAGED IDENTITIES:" -ForegroundColor Yellow
Write-DeploymentInfo "Function App" $deployment.Outputs.functionAppIdentityPrincipalId.Value
Write-Host ""
#endregion

#region Next Steps
Write-Host ""
Write-Host "=========================================="
Write-Host "NEXT STEPS (Required Manual Actions)"
Write-Host "==========================================" -ForegroundColor Yellow
Write-Host ""

Write-Host "1. GRANT GRAPH API PERMISSIONS (CRITICAL)" -ForegroundColor Red
Write-Host "   This is required for data collection to work"
Write-Host ""
Write-Host "   Steps:"
Write-Host "   a. Open Azure Portal → Entra ID → Enterprise Applications"
Write-Host "   b. Search for: $($deployment.Outputs.functionAppName.Value)"
Write-Host "   c. Click 'API Permissions' → 'Add a permission'"
Write-Host "   d. Select 'Microsoft Graph' → 'Application permissions'"
Write-Host "   e. Search and select: 'User.Read.All'"
Write-Host "   f. Click 'Add permissions'"
Write-Host "   g. Click 'Grant admin consent for [tenant]'"
Write-Host "   h. Confirm grant"
Write-Host ""

Write-Host "2. DEPLOY POWERSHELL MODULE" -ForegroundColor Yellow
Write-Host "   Run the module publishing pipeline:"
Write-Host "   - Azure DevOps → Pipelines"
Write-Host "   - Select: EntraDataCollection.Module/.azure-pipelines/publish-module.yml"
Write-Host "   - Run pipeline and wait for completion"
Write-Host ""

Write-Host "3. DEPLOY FUNCTION APP CODE" -ForegroundColor Yellow
Write-Host "   Run the application deployment pipeline:"
Write-Host "   - Azure DevOps → Pipelines"
Write-Host "   - Select: .azure-pipelines/pilot-pipeline.yml"
Write-Host "   - Approve deployment when prompted"
Write-Host ""

Write-Host "4. (OPTIONAL) DEPLOY AI MODEL" -ForegroundColor Gray
Write-Host "   For AI Foundry testing:"
Write-Host "   - Visit: https://ai.azure.com"
Write-Host "   - Navigate to your project"
Write-Host "   - Deploy 'gpt-4o-mini' model"
Write-Host ""

Write-Host "5. TEST THE DEPLOYMENT" -ForegroundColor Yellow
Write-Host "   After steps 1-3 are complete:"
Write-Host "   - Trigger via HTTP endpoint or wait for timer (every 6 hours)"
Write-Host "   - Check Application Insights for logs"
Write-Host "   - Verify data in Blob Storage (raw-data container)"
Write-Host "   - Verify data in Cosmos DB (users_raw container)"
Write-Host "   - Check user_changes container for deltas"
Write-Host ""
#endregion

#region Architecture Summary
Write-Host ""
Write-Host "=========================================="
Write-Host "ARCHITECTURE SUMMARY"
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "DATA FLOW:" -ForegroundColor Yellow
Write-Host "  1. Entra ID → CollectEntraUsers → Blob Storage (2-3 min)"
Write-Host "  2. Blob → IndexInCosmosDB → Delta Detection"
Write-Host "  3. Cosmos DB (write changed users only)"
Write-Host "  4. Power BI → Query Cosmos DB"
Write-Host ""

Write-Host "DELTA CHANGE DETECTION:" -ForegroundColor Yellow
Write-Host "  - First run: Writes all users to Cosmos"
Write-Host "  - Subsequent runs: Writes only changes (~0.5% of users)"
Write-Host "  - Write reduction: 99% (1,250 writes vs 250,000 users)"
Write-Host "  - Cost reduction: ~96% on Cosmos writes"
Write-Host ""

Write-Host "RETENTION POLICY:" -ForegroundColor Yellow
Write-Host "  - Blob Storage: $BlobRetentionDays days (auto-delete old files)"
Write-Host "  - Cosmos user_changes: 365 days (change history)"
Write-Host "  - Cosmos users_raw: Permanent (current state)"
Write-Host ""

Write-Host "ESTIMATED COSTS:" -ForegroundColor Yellow
Write-Host "  - Month 1 (initial load): ~`$2-3"
Write-Host "  - Month 2+ (delta only): ~`$1-2"
Write-Host "  - Annual: ~`$15-25"
Write-Host ""
#endregion

#region Save Deployment Info
$deploymentInfo = @{
    DeploymentName = $deploymentName
    DeploymentDate = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    ResourceGroupName = $ResourceGroupName
    SubscriptionId = $SubscriptionId
    Location = $Location
    Environment = $Environment
    BlobRetentionDays = $BlobRetentionDays
    Architecture = 'DeltaChangeDetection'
    
    Resources = @{
        StorageAccount = $deployment.Outputs.storageAccountName.Value
        FunctionApp = $deployment.Outputs.functionAppName.Value
        CosmosDBAccount = $deployment.Outputs.cosmosDbAccountName.Value
        CosmosDatabase = $deployment.Outputs.cosmosDatabaseName.Value
        CosmosContainers = @{
            UsersRaw = $deployment.Outputs.cosmosContainerUsersRaw.Value
            UserChanges = $deployment.Outputs.cosmosContainerUserChanges.Value
            Snapshots = $deployment.Outputs.cosmosContainerSnapshots.Value
        }
        KeyVault = $deployment.Outputs.keyVaultName.Value
        ApplicationInsights = $deployment.Outputs.appInsightsName.Value
        AIFoundryHub = $deployment.Outputs.aiFoundryHubName.Value
        AIFoundryProject = $deployment.Outputs.aiFoundryProjectName.Value
    }
    
    ManagedIdentities = @{
        FunctionApp = $deployment.Outputs.functionAppIdentityPrincipalId.Value
    }
    
    NextSteps = @{
        GraphAPIPermissions = "Required - See steps above"
        ModulePublishing = "Required - Run publish-module.yml"
        AppDeployment = "Required - Run pilot-pipeline.yml"
        AIModelDeployment = "Optional - Deploy in AI Foundry portal"
    }
}

$infoPath = Join-Path $PSScriptRoot "deployment-info-delta-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
$deploymentInfo | ConvertTo-Json -Depth 10 | Set-Content -Path $infoPath

Write-Host ""
Write-Host "Deployment information saved to:" -ForegroundColor Gray
Write-Host "  $infoPath"
Write-Host ""
#endregion

#region Final Message
Write-Host "=========================================="
Write-Host "Deployment script completed successfully!" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Remember to complete the 5 manual steps above before testing." -ForegroundColor Yellow
Write-Host ""
#endregion
