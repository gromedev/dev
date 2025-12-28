@{
    RootModule = 'EntraDataCollection.psm1'
    ModuleVersion = '1.1.0'
    GUID = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'
    Author = 'Entra Risk Analysis Team'
    CompanyName = 'Unknown'
    Copyright = '(c) 2024. All rights reserved.'
    Description = 'PowerShell module for Microsoft Entra ID data collection and Cosmos DB operations'
    
    PowerShellVersion = '7.2'
    
    FunctionsToExport = @(
        'Get-ManagedIdentityToken',
        'Invoke-GraphWithRetry',
        'Test-MemoryPressure',
        'Initialize-AppendBlob',
        'Add-BlobContent',
        'Get-BlobCheckpoint',
        'Set-BlobCheckpoint',
        'Write-CosmosDocument',
        'Write-CosmosBatch',
        'Get-CosmosDocuments'
    )
    
    CmdletsToExport = @()
    VariablesToExport = '*'
    AliasesToExport = @()
    
    PrivateData = @{
        PSData = @{
            Tags = @('Entra', 'Azure', 'AD', 'Identity', 'Security', 'Cosmos', 'DataCollection')
            LicenseUri = ''
            ProjectUri = ''
            IconUri = ''
            ReleaseNotes = 'v1.1.0: Added Cosmos DB functions (Write-CosmosDocument, Write-CosmosBatch, Get-CosmosDocuments)'
        }
    }
}
