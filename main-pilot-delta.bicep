@description('The workload name used for naming resources')
param workloadName string = 'entrarisk'

@description('The environment name (dev, test, prod)')
@allowed([
  'dev'
  'test'
  'prod'
])
param environment string = 'dev'

@description('The Azure region for resources')
param location string = resourceGroup().location

@description('Entra ID Tenant ID for authentication')
param tenantId string

@description('Blob retention days (7 for pilot, 30 for production)')
param blobRetentionDays int = 7

@description('Tags to apply to all resources')
param tags object = {
  Environment: environment
  Workload: workloadName
  ManagedBy: 'Bicep'
  CostCenter: 'IT-Security'
  Project: 'EntraRiskAnalysis-Delta'
  Version: '2.0-Delta'
}

// Generate unique suffix for globally unique names
var uniqueSuffix = uniqueString(resourceGroup().id)

// Resource names
var storageAccountName = take('st${workloadName}${environment}${uniqueSuffix}', 24)
var cosmosDbAccountName = 'cosno-${workloadName}-${environment}-${uniqueSuffix}'
var functionAppName = 'func-${workloadName}-data-${environment}-${uniqueSuffix}'
var appServicePlanName = 'asp-${workloadName}-${environment}-001'
var keyVaultName = take('kv${workloadName}${environment}${uniqueSuffix}', 24)
var appInsightsName = 'appi-${workloadName}-${environment}-001'
var logAnalyticsName = 'log-${workloadName}-${environment}-001'
var aiFoundryHubName = 'hub-${workloadName}-${environment}-${uniqueSuffix}'
var aiFoundryProjectName = 'proj-${workloadName}-${environment}-${uniqueSuffix}'

//==============================================================================
// STORAGE ACCOUNT WITH LIFECYCLE MANAGEMENT
//==============================================================================

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
}

resource rawDataContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'raw-data'
  properties: {
    publicAccess: 'None'
    metadata: {
      purpose: 'Landing zone for Graph API exports'
      retention: '${blobRetentionDays} days'
    }
  }
}

resource analysisContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'analysis'
  properties: {
    publicAccess: 'None'
  }
}

// Lifecycle policy to auto-delete old blobs
resource blobLifecyclePolicy 'Microsoft.Storage/storageAccounts/managementPolicies@2023-01-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    policy: {
      rules: [
        {
          name: 'delete-old-raw-data'
          enabled: true
          type: 'Lifecycle'
          definition: {
            filters: {
              blobTypes: ['blockBlob']
              prefixMatch: ['raw-data/']
            }
            actions: {
              baseBlob: {
                delete: {
                  daysAfterModificationGreaterThan: blobRetentionDays
                }
              }
            }
          }
        }
      ]
    }
  }
}

//==============================================================================
// COSMOS DB - THREE CONTAINERS
//==============================================================================

resource cosmosDbAccount 'Microsoft.DocumentDB/databaseAccounts@2023-04-15' = {
  name: cosmosDbAccountName
  location: location
  tags: tags
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
    locations: [
      {
        locationName: location
        failoverPriority: 0
        isZoneRedundant: false
      }
    ]
    capabilities: [
      {
        name: 'EnableServerless'
      }
    ]
    enableFreeTier: true
    backupPolicy: {
      type: 'Continuous'
      continuousModeProperties: {
        tier: 'Continuous7Days'
      }
    }
  }
}

resource cosmosDatabase 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2023-04-15' = {
  parent: cosmosDbAccount
  name: 'EntraData'
  properties: {
    resource: {
      id: 'EntraData'
    }
  }
}

// Container 1: Current state of all users
resource cosmosContainerUsersRaw 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2023-04-15' = {
  parent: cosmosDatabase
  name: 'users_raw'
  properties: {
    resource: {
      id: 'users_raw'
      partitionKey: {
        paths: ['/objectId']
        kind: 'Hash'
      }
      indexingPolicy: {
        automatic: true
        indexingMode: 'consistent'
        includedPaths: [
          { path: '/objectId/?' }
          { path: '/userPrincipalName/?' }
          { path: '/accountEnabled/?' }
          { path: '/userType/?' }
          { path: '/lastSignInDateTime/?' }
          { path: '/collectionTimestamp/?' }
          { path: '/lastModified/?' }
        ]
        excludedPaths: [
          { path: '/*' }
        ]
      }
      uniqueKeyPolicy: {
        uniqueKeys: [
          {
            paths: ['/objectId']
          }
        ]
      }
      defaultTtl: -1
    }
  }
}

// Container 2: Change log (audit trail)
resource cosmosContainerUserChanges 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2023-04-15' = {
  parent: cosmosDatabase
  name: 'user_changes'
  properties: {
    resource: {
      id: 'user_changes'
      partitionKey: {
        paths: ['/snapshotId']
        kind: 'Hash'
      }
      indexingPolicy: {
        automatic: true
        indexingMode: 'consistent'
        includedPaths: [
          { path: '/objectId/?' }
          { path: '/changeType/?' }
          { path: '/changeTimestamp/?' }
          { path: '/snapshotId/?' }
        ]
        excludedPaths: [
          { path: '/*' }
        ]
      }
      defaultTtl: 31536000  // 365 days
    }
  }
}

// Container 3: Collection metadata and summaries
resource cosmosContainerSnapshots 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2023-04-15' = {
  parent: cosmosDatabase
  name: 'snapshots'
  properties: {
    resource: {
      id: 'snapshots'
      partitionKey: {
        paths: ['/id']
        kind: 'Hash'
      }
      indexingPolicy: {
        automatic: true
        indexingMode: 'consistent'
      }
      defaultTtl: -1
    }
  }
}

//==============================================================================
// KEY VAULT, MONITORING, FUNCTION APP (Same as before)
//==============================================================================

resource keyVault 'Microsoft.KeyVault/vaults@2023-02-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: tenantId
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enableRbacAuthorization: true
    enabledForDeployment: false
    enabledForTemplateDeployment: true
  }
}

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: logAnalyticsName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
}

resource appServicePlan 'Microsoft.Web/serverfarms@2022-09-01' = {
  name: appServicePlanName
  location: location
  tags: tags
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  properties: {}
}

resource functionApp 'Microsoft.Web/sites@2022-09-01' = {
  name: functionAppName
  location: location
  tags: tags
  kind: 'functionapp'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      powerShellVersion: '7.2'
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'
        }
        {
          name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'
        }
        {
          name: 'WEBSITE_CONTENTSHARE'
          value: toLower(functionAppName)
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'powershell'
        }
        {
          name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
          value: appInsights.properties.InstrumentationKey
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'STORAGE_ACCOUNT_NAME'
          value: storageAccount.name
        }
        {
          name: 'COSMOS_DB_ENDPOINT'
          value: cosmosDbAccount.properties.documentEndpoint
        }
        {
          name: 'COSMOS_DB_DATABASE'
          value: cosmosDatabase.name
        }
        {
          name: 'COSMOS_CONTAINER_USERS_RAW'
          value: cosmosContainerUsersRaw.name
        }
        {
          name: 'COSMOS_CONTAINER_USER_CHANGES'
          value: cosmosContainerUserChanges.name
        }
        {
          name: 'COSMOS_CONTAINER_SNAPSHOTS'
          value: cosmosContainerSnapshots.name
        }
        {
          name: 'KEY_VAULT_URI'
          value: keyVault.properties.vaultUri
        }
        {
          name: 'TENANT_ID'
          value: tenantId
        }
        {
          name: 'AI_FOUNDRY_ENDPOINT'
          value: aiFoundryHub.properties.discoveryUrl
        }
        {
          name: 'AI_FOUNDRY_PROJECT_NAME'
          value: aiFoundryProjectName
        }
        {
          name: 'AI_MODEL_DEPLOYMENT_NAME'
          value: 'gpt-4o-mini'
        }
        // Collection Configuration
        {
          name: 'BATCH_SIZE'
          value: '999'
        }
        {
          name: 'PARALLEL_THROTTLE'
          value: '10'
        }
        // Memory Configuration (Consumption Plan)
        {
          name: 'MEMORY_THRESHOLD_GB'
          value: '1.0'
        }
        {
          name: 'MEMORY_WARNING_GB'
          value: '0.8'
        }
        {
          name: 'MEMORY_CHECK_INTERVAL'
          value: '5'
        }
        // Cosmos DB Configuration
        {
          name: 'COSMOS_BATCH_SIZE'
          value: '100'
        }
        {
          name: 'ENABLE_DELTA_DETECTION'
          value: 'true'
        }
        // Blob Retention
        {
          name: 'BLOB_RETENTION_DAYS'
          value: string(blobRetentionDays)
        }
      ]
    }
  }
}

resource aiFoundryHub 'Microsoft.MachineLearningServices/workspaces@2024-04-01' = {
  name: aiFoundryHubName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'Basic'
    tier: 'Basic'
  }
  kind: 'Hub'
  properties: {
    friendlyName: 'Entra Risk Analysis AI Hub - Delta'
    description: 'AI Foundry Hub with delta change detection'
    storageAccount: storageAccount.id
    keyVault: keyVault.id
    applicationInsights: appInsights.id
  }
}

resource aiFoundryProject 'Microsoft.MachineLearningServices/workspaces@2024-04-01' = {
  name: aiFoundryProjectName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'Basic'
    tier: 'Basic'
  }
  kind: 'Project'
  properties: {
    friendlyName: 'Entra Risk Analysis Project - Delta'
    description: 'AI project with change tracking'
    hubResourceId: aiFoundryHub.id
  }
}

//==============================================================================
// RBAC ASSIGNMENTS
//==============================================================================

resource functionAppStorageRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionApp.id, 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource functionAppCosmosRoleAssignment 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2023-04-15' = {
  parent: cosmosDbAccount
  name: guid(functionApp.identity.principalId, cosmosDbAccount.id, '00000000-0000-0000-0000-000000000002')
  properties: {
    roleDefinitionId: '${cosmosDbAccount.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002'
    principalId: functionApp.identity.principalId
    scope: cosmosDbAccount.id
  }
}

resource functionAppKeyVaultRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, functionApp.id, '4633458b-17de-408a-b874-0445c86b69e6')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource aiFoundryStorageRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, aiFoundryHub.id, 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
    principalId: aiFoundryHub.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource aiFoundryCosmosRoleAssignment 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2023-04-15' = {
  parent: cosmosDbAccount
  name: guid(aiFoundryHub.identity.principalId, cosmosDbAccount.id, '00000000-0000-0000-0000-000000000001')
  properties: {
    roleDefinitionId: '${cosmosDbAccount.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000001'
    principalId: aiFoundryHub.identity.principalId
    scope: cosmosDbAccount.id
  }
}

//==============================================================================
// OUTPUTS
//==============================================================================

output storageAccountName string = storageAccount.name
output functionAppName string = functionApp.name
output cosmosDbAccountName string = cosmosDbAccount.name
output cosmosDbEndpoint string = cosmosDbAccount.properties.documentEndpoint
output cosmosDatabaseName string = cosmosDatabase.name
output cosmosContainerUsersRaw string = cosmosContainerUsersRaw.name
output cosmosContainerUserChanges string = cosmosContainerUserChanges.name
output cosmosContainerSnapshots string = cosmosContainerSnapshots.name
output keyVaultName string = keyVault.name
output appInsightsName string = appInsights.name
output functionAppIdentityPrincipalId string = functionApp.identity.principalId
output blobRetentionDays int = blobRetentionDays
