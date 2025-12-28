#region Index in Cosmos DB Activity - DELTA CHANGE DETECTION
<#
.SYNOPSIS
    Indexes users in Cosmos DB with delta change detection
.DESCRIPTION
    - Reads users from Blob Storage (JSONL format)
    - Compares with existing Cosmos DB state
    - Writes only changed users (upsert)
    - Logs all changes to user_changes container
    - Writes summary to snapshots container
    
    Change Types:
    - new: User doesn't exist in Cosmos
    - modified: User exists but properties changed
    - deleted: User exists in Cosmos but not in current export
    - unchanged: User exists with identical properties (skip write)
    
    Cost Optimization:
    - First run: Writes all users (~$0.20 for 250K users)
    - Subsequent runs: Writes only changes (~$0.11 for 1,400 changes)
    - 99.5% write reduction
#>
#endregion

param($ActivityInput)

Import-Module EntraDataCollection

try {
    Write-Verbose "Starting Cosmos DB indexing with delta detection"
    
    # Get configuration
    $cosmosEndpoint = $env:COSMOS_DB_ENDPOINT
    $cosmosDatabase = $env:COSMOS_DB_DATABASE
    $containerUsersRaw = $env:COSMOS_CONTAINER_USERS_RAW
    $containerUserChanges = $env:COSMOS_CONTAINER_USER_CHANGES
    $containerSnapshots = $env:COSMOS_CONTAINER_SNAPSHOTS
    $storageAccountName = $env:STORAGE_ACCOUNT_NAME
    $enableDelta = $env:ENABLE_DELTA_DETECTION -eq 'true'
    
    $timestamp = $ActivityInput.Timestamp
    $userCount = $ActivityInput.UserCount
    $blobName = $ActivityInput.BlobName
    
    Write-Verbose "Configuration:"
    Write-Verbose "  Blob: $blobName"
    Write-Verbose "  Users: $userCount"
    Write-Verbose "  Delta detection: $enableDelta"
    
    # Get tokens
    $cosmosToken = Get-ManagedIdentityToken -Resource "https://cosmos.azure.com"
    $storageToken = Get-ManagedIdentityToken -Resource "https://storage.azure.com"
    
    #region Step 1: Read users from Blob
    Write-Verbose "Reading users from Blob Storage..."
    
    # Get blob content
    $blobUri = "https://$storageAccountName.blob.core.windows.net/raw-data/$blobName"
    $headers = @{
        'Authorization' = "Bearer $storageToken"
        'x-ms-version' = '2021-08-06'
        'x-ms-blob-type' = 'AppendBlob'
    }
    
    $blobContent = Invoke-RestMethod -Uri $blobUri -Method Get -Headers $headers
    
    # Parse JSONL into HashMap for fast lookup
    $currentUsers = @{}
    $lineNumber = 0
    
    foreach ($line in ($blobContent -split "`n")) {
        $lineNumber++
        if ($line.Trim()) {
            try {
                $user = $line | ConvertFrom-Json
                $currentUsers[$user.objectId] = $user
            }
            catch {
                Write-Warning "Failed to parse line $lineNumber`: $_"
            }
        }
    }
    
    Write-Verbose "Parsed $($currentUsers.Count) users from Blob"
    #endregion
    
    #region Step 2: Read existing users from Cosmos (if delta enabled)
    $existingUsers = @{}
    
    if ($enableDelta) {
        Write-Verbose "Reading existing users from Cosmos DB for delta comparison..."
        
        $query = "SELECT c.objectId, c.userPrincipalName, c.accountEnabled, c.userType, c.lastSignInDateTime, c.lastModified FROM c"
        
        try {
            $cosmosUsers = Get-CosmosDocuments `
                -Endpoint $cosmosEndpoint `
                -Database $cosmosDatabase `
                -Container $containerUsersRaw `
                -Query $query `
                -AccessToken $cosmosToken
            
            foreach ($user in $cosmosUsers) {
                $existingUsers[$user.objectId] = $user
            }
            
            Write-Verbose "Found $($existingUsers.Count) existing users in Cosmos"
        }
        catch {
            Write-Warning "Could not read existing users (first run?): $_"
            # First run - no existing users
        }
    }
    #endregion
    
    #region Step 3: Delta detection
    $newUsers = @()
    $modifiedUsers = @()
    $unchangedUsers = @()
    $deletedUsers = @()
    $changeLog = @()
    
    # Check current users
    foreach ($objectId in $currentUsers.Keys) {
        $currentUser = $currentUsers[$objectId]
        
        if (-not $existingUsers.ContainsKey($objectId)) {
            # NEW user
            $newUsers += $currentUser
            
            $changeLog += @{
                id = [Guid]::NewGuid().ToString()
                objectId = $objectId
                changeType = 'new'
                changeTimestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                snapshotId = $timestamp
                newValue = $currentUser
            }
        }
        else {
            # Check if modified
            $existingUser = $existingUsers[$objectId]
            
            $changed = $false
            $delta = @{}
            
            # Compare key fields
            $fieldsToCompare = @('accountEnabled', 'userType', 'lastSignInDateTime', 'userPrincipalName')
            
            foreach ($field in $fieldsToCompare) {
                $currentValue = $currentUser.$field
                $existingValue = $existingUser.$field
                
                if ($currentValue -ne $existingValue) {
                    $changed = $true
                    $delta[$field] = @{
                        old = $existingValue
                        new = $currentValue
                    }
                }
            }
            
            if ($changed) {
                # MODIFIED user
                $modifiedUsers += $currentUser
                
                $changeLog += @{
                    id = [Guid]::NewGuid().ToString()
                    objectId = $objectId
                    changeType = 'modified'
                    changeTimestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                    snapshotId = $timestamp
                    previousValue = $existingUser
                    newValue = $currentUser
                    delta = $delta
                }
            }
            else {
                # UNCHANGED
                $unchangedUsers += $objectId
            }
        }
    }
    
    # Check for deleted users
    if ($enableDelta) {
        foreach ($objectId in $existingUsers.Keys) {
            if (-not $currentUsers.ContainsKey($objectId)) {
                # DELETED user
                $deletedUsers += $existingUsers[$objectId]
                
                $changeLog += @{
                    id = [Guid]::NewGuid().ToString()
                    objectId = $objectId
                    changeType = 'deleted'
                    changeTimestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                    snapshotId = $timestamp
                    previousValue = $existingUsers[$objectId]
                }
            }
        }
    }
    
    Write-Verbose "Delta summary:"
    Write-Verbose "  New: $($newUsers.Count)"
    Write-Verbose "  Modified: $($modifiedUsers.Count)"
    Write-Verbose "  Deleted: $($deletedUsers.Count)"
    Write-Verbose "  Unchanged: $($unchangedUsers.Count)"
    #endregion
    
    #region Step 4: Write changes to Cosmos users_raw
    $usersToWrite = @()
    $usersToWrite += $newUsers
    $usersToWrite += $modifiedUsers
    
    if ($usersToWrite.Count -gt 0 -or (-not $enableDelta)) {
        Write-Verbose "Writing $($usersToWrite.Count) changed users to Cosmos..."
        
        # If delta disabled, write all users
        if (-not $enableDelta) {
            $usersToWrite = $currentUsers.Values
            Write-Verbose "Delta detection disabled - writing all $($usersToWrite.Count) users"
        }
        
        # Prepare documents for Cosmos
        $docsToWrite = @()
        foreach ($user in $usersToWrite) {
            $docsToWrite += @{
                id = $user.objectId
                objectId = $user.objectId
                userPrincipalName = $user.userPrincipalName
                accountEnabled = $user.accountEnabled
                userType = $user.userType
                createdDateTime = $user.createdDateTime
                lastSignInDateTime = $user.lastSignInDateTime
                collectionTimestamp = $user.collectionTimestamp
                lastModified = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                snapshotId = $timestamp
            }
        }
        
        # Batch write
        $writtenCount = Write-CosmosBatch `
            -Endpoint $cosmosEndpoint `
            -Database $cosmosDatabase `
            -Container $containerUsersRaw `
            -Documents $docsToWrite `
            -AccessToken $cosmosToken `
            -BatchSize 100
        
        Write-Verbose "Written $writtenCount users to $containerUsersRaw"
    }
    else {
        Write-Verbose "No changes detected - skipping user writes"
    }
    #endregion
    
    #region Step 5: Write change log
    if ($changeLog.Count -gt 0) {
        Write-Verbose "Writing $($changeLog.Count) change events to Cosmos..."
        
        $writtenChanges = Write-CosmosBatch `
            -Endpoint $cosmosEndpoint `
            -Database $cosmosDatabase `
            -Container $containerUserChanges `
            -Documents $changeLog `
            -AccessToken $cosmosToken `
            -BatchSize 100
        
        Write-Verbose "Written $writtenChanges change events to $containerUserChanges"
    }
    #endregion
    
    #region Step 6: Write snapshot summary
    $snapshotDoc = @{
        id = $timestamp
        snapshotId = $timestamp
        collectionTimestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        collectionType = 'users'
        totalUsers = $currentUsers.Count
        newUsers = $newUsers.Count
        modifiedUsers = $modifiedUsers.Count
        deletedUsers = $deletedUsers.Count
        unchangedUsers = $unchangedUsers.Count
        cosmosWriteCount = $usersToWrite.Count
        blobPath = $blobName
        deltaDetectionEnabled = $enableDelta
    }
    
    Write-CosmosDocument `
        -Endpoint $cosmosEndpoint `
        -Database $cosmosDatabase `
        -Container $containerSnapshots `
        -Document $snapshotDoc `
        -AccessToken $cosmosToken
    
    Write-Verbose "Snapshot summary written to $containerSnapshots"
    #endregion
    
    Write-Verbose "Cosmos DB indexing complete!"
    
    return @{
        Success = $true
        TotalUsers = $currentUsers.Count
        NewUsers = $newUsers.Count
        ModifiedUsers = $modifiedUsers.Count
        DeletedUsers = $deletedUsers.Count
        UnchangedUsers = $unchangedUsers.Count
        CosmosWriteCount = $usersToWrite.Count
        SnapshotId = $timestamp
    }
}
catch {
    Write-Error "Cosmos DB indexing failed: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
    }
}
