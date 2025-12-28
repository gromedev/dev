<#
.SYNOPSIS
    Collects user data from Microsoft Entra ID and streams to Blob Storage
.DESCRIPTION
    - Queries Graph API with pagination and parallel processing
    - Streams JSONL output to Blob Storage (memory-efficient)
    - Returns summary statistics for orchestrator
    - Optimized for large tenants (250K+ users)
#>
#endregion

param($ActivityInput)

#region Import and Validate
Import-Module EntraDataCollection

# Validate required environment variables
$requiredEnvVars = @{
    'STORAGE_ACCOUNT_NAME' = 'Storage account for data collection'
    'COSMOS_DB_ENDPOINT' = 'Cosmos DB endpoint for indexing'
    'COSMOS_DB_DATABASE' = 'Cosmos DB database name'
    'TENANT_ID' = 'Entra ID tenant ID'
}

$missingVars = @()
foreach ($varName in $requiredEnvVars.Keys) {
    if (-not (Get-Item "Env:$varName" -ErrorAction SilentlyContinue)) {
        $missingVars += "$varName ($($requiredEnvVars[$varName]))"
    }
}

if ($missingVars) {
    $errorMsg = "Missing required environment variables:`n" + ($missingVars -join "`n")
    Write-Error $errorMsg
    return @{
        Success = $false
        Error = $errorMsg
    }
}
#endregion

#region Function Logic
try {
    Write-Verbose "Starting Entra user data collection"
    
    # Generate ISO 8601 timestamps
    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH-mm-ssZ")
    $timestampFormatted = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    Write-Verbose "Collection timestamp: $timestampFormatted"
    
    # Get access tokens
    Write-Verbose "Acquiring access tokens with managed identity"
    try {
        $graphToken = Get-ManagedIdentityToken -Resource "https://graph.microsoft.com"
        $storageToken = Get-ManagedIdentityToken -Resource "https://storage.azure.com"
    }
    catch {
        Write-Error "Failed to acquire tokens: $_"
        return @{
            Success = $false
            Error = "Token acquisition failed: $($_.Exception.Message)"
        }
    }
    
    # Get configuration
    $storageAccountName = $env:STORAGE_ACCOUNT_NAME
    $batchSize = if ($env:BATCH_SIZE) { [int]$env:BATCH_SIZE } else { 999 }
    $parallelThrottle = if ($env:PARALLEL_THROTTLE) { [int]$env:PARALLEL_THROTTLE } else { 10 }
    $memoryThresholdGB = if ($env:MEMORY_THRESHOLD_GB) { [double]$env:MEMORY_THRESHOLD_GB } else { 1.0 }
    $memoryWarningGB = if ($env:MEMORY_WARNING_GB) { [double]$env:MEMORY_WARNING_GB } else { 0.8 }
    $memoryCheckInterval = if ($env:MEMORY_CHECK_INTERVAL) { [int]$env:MEMORY_CHECK_INTERVAL } else { 5 }
    
    Write-Verbose "Configuration: Batch=$batchSize, Parallel=$parallelThrottle, MemoryThreshold=$memoryThresholdGB GB"
    
    # Initialize counters and buffers
    # Pre-allocate StringBuilder capacity for ~5000 users to prevent reallocation spikes
    # Each user ~200 bytes JSON = 1MB buffer (matches flush threshold)
    $usersJsonL = New-Object System.Text.StringBuilder(1048576)  # 1MB initial capacity
    $userCount = 0
    $batchNumber = 0
    $writeThreshold = 5000
    
    # Summary statistics
    $enabledCount = 0
    $disabledCount = 0
    $memberCount = 0
    $guestCount = 0
    
    # Initialize append blob
    $usersBlobName = "$timestamp/$timestamp-users.jsonl"
    Write-Verbose "Initializing append blob: $usersBlobName"
    
    try {
        Initialize-AppendBlob -StorageAccountName $storageAccountName `
                              -ContainerName 'raw-data' `
                              -BlobName $usersBlobName `
                              -AccessToken $storageToken
    }
    catch {
        Write-Error "Failed to initialize blob: $_"
        return @{
            Success = $false
            Error = "Blob initialization failed: $($_.Exception.Message)"
        }
    }
    
    # Query users with field selection
    $selectFields = "userPrincipalName,id,accountEnabled,userType,createdDateTime,signInActivity"
    $nextLink = "https://graph.microsoft.com/v1.0/users?`$select=$selectFields&`$top=$batchSize"
    
    Write-Verbose "Starting batch processing with streaming writes"
    
    # Process batches
    while ($nextLink) {
        $batchNumber++
        Write-Verbose "Processing batch $batchNumber..."
        
        # Memory monitoring every N batches
        if ($batchNumber % $memoryCheckInterval -eq 0) {
            if (Test-MemoryPressure -ThresholdGB $memoryThresholdGB -WarningGB $memoryWarningGB) {
                Write-Verbose "Memory cleanup triggered at batch $batchNumber"
            }
        }
        
        # Get batch from Graph API
        try {
            $response = Invoke-GraphWithRetry -Uri $nextLink -AccessToken $graphToken
            $userBatch = $response.value
            $nextLink = $response.'@odata.nextLink'
        }
        catch {
            Write-Error "Failed to retrieve batch $batchNumber`: $_"
            Write-Warning "Skipping batch $batchNumber due to error"
            continue
        }
        
        if ($userBatch.Count -eq 0) { break }
        
        # Parallel process batch
        $batchResults = $userBatch | ForEach-Object -ThrottleLimit $parallelThrottle -Parallel {
            $user = $_
            $localTimestamp = $using:timestampFormatted
            
            # Transform to consistent camelCase structure with objectId
            $userObj = @{
                objectId = $user.id ?? ""
                userPrincipalName = $user.userPrincipalName ?? ""
                accountEnabled = if ($null -ne $user.accountEnabled) { $user.accountEnabled } else { $null }
                userType = $user.userType ?? ""
                createdDateTime = $user.createdDateTime ?? ""
                lastSignInDateTime = if ($user.signInActivity.lastSignInDateTime) { 
                    $user.signInActivity.lastSignInDateTime 
                } else { 
                    $null 
                }
                collectionTimestamp = $localTimestamp
            }
            
            @{
                JsonLine = ($userObj | ConvertTo-Json -Compress)
                AccountEnabled = $userObj.accountEnabled
                UserType = $userObj.userType
            }
        }
        
        # Append results and track statistics
        foreach ($result in $batchResults) {
            [void]$usersJsonL.AppendLine($result.JsonLine)
            $userCount++
            
            # Track summary statistics
            if ($result.AccountEnabled -eq $true) { $enabledCount++ }
            elseif ($result.AccountEnabled -eq $false) { $disabledCount++ }
            
            if ($result.UserType -eq 'Member') { $memberCount++ }
            elseif ($result.UserType -eq 'Guest') { $guestCount++ }
        }
        
        # Periodic flush to blob (every ~5000 users)
        if ($usersJsonL.Length -ge ($writeThreshold * 200)) {
            try {
                Add-BlobContent -StorageAccountName $storageAccountName `
                                -ContainerName 'raw-data' `
                                -BlobName $usersBlobName `
                                -Content $usersJsonL.ToString() `
                                -AccessToken $storageToken
                
                Write-Verbose "Flushed $($usersJsonL.Length) characters to blob (batch $batchNumber)"
                $usersJsonL.Clear()
            }
            catch {
                Write-Error "Failed to flush to blob at batch $batchNumber`: $_"
                # Continue - we'll try again at next flush
            }
        }
        
        Write-Verbose "Batch $batchNumber complete: $userCount total users"
    }
    
    # Final flush
    if ($usersJsonL.Length -gt 0) {
        Add-BlobContent -StorageAccountName $storageAccountName `
                        -ContainerName 'raw-data' `
                        -BlobName $usersBlobName `
                        -Content $usersJsonL.ToString() `
                        -AccessToken $storageToken
        Write-Verbose "Final flush: $($usersJsonL.Length) characters written"
    }
    
    Write-Verbose "User collection complete: $userCount users written to $usersBlobName"
    
    # Cleanup
    $usersJsonL.Clear()
    $usersJsonL = $null
    
    # Create summary
    $summary = @{
        id = $timestamp
        collectionTimestamp = $timestampFormatted
        collectionType = 'users'
        totalCount = $userCount
        enabledCount = $enabledCount
        disabledCount = $disabledCount
        memberCount = $memberCount
        guestCount = $guestCount
        blobPath = $usersBlobName
    }
    
    # Garbage collection
    Write-Verbose "Performing garbage collection"
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    [System.GC]::Collect()
    
    Write-Verbose "Collection activity completed successfully!"
    
    return @{
        Success = $true
        UserCount = $userCount
        Data = @()
        Summary = $summary
        FileName = "$timestamp-users.jsonl"
        Timestamp = $timestamp
        BlobName = $usersBlobName
    }
}
catch {
    Write-Error "Unexpected error in CollectEntraUsers: $_"
    return @{
        Success = $false
        Error = $_.Exception.Message
    }
}
