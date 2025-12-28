
#region Durable Functions Orchestrator - DELTA ARCHITECTURE
<#
.SYNOPSIS
    Orchestrates Entra user data collection with delta change detection
.DESCRIPTION
    Workflow:
    1. CollectEntraUsers - Streams to Blob Storage (2-3 minutes)
    2. IndexInCosmosDB - Delta detection and write changes only
    3. TestAIFoundry - Optional connectivity test
    
    Benefits of this flow:
    - Fast collection (streaming to Blob)
    - Decoupled indexing (can retry independently)
    - Delta detection reduces Cosmos writes by 99%
    - Blob acts as checkpoint/buffer
    
    Partial Success Pattern:
    - CollectEntraUsers fails → STOP (critical, no data)
    - IndexInCosmosDB fails → CONTINUE (data safe in Blob, can retry)
    - TestAIFoundry fails → CONTINUE (optional feature)
#>
#endregion

param($Context)

try {
    Write-Verbose "Starting Entra data collection orchestration"
    Write-Verbose "Instance ID: $($Context.InstanceId)"
    
    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH-mm-ssZ")
    $timestampFormatted = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    
    Write-Verbose "Collection timestamp: $timestampFormatted"
    
    #region Step 1: Collect Entra Users
    Write-Verbose "Step 1: Collecting users from Entra ID..."
    
    $collectionInput = @{
        Timestamp = $timestamp
    }
    
    $collectionResult = Invoke-DurableActivity `
        -FunctionName 'CollectEntraUsers' `
        -Input $collectionInput
    
    if (-not $collectionResult.Success) {
        throw "User collection failed: $($collectionResult.Error)"
    }
    
    Write-Verbose "Collection complete: $($collectionResult.UserCount) users"
    Write-Verbose "Blob created: $($collectionResult.BlobName)"
    #endregion
    
    #region Step 2: Index in Cosmos DB with Delta Detection
    Write-Verbose "Step 2: Indexing users in Cosmos DB with delta detection..."
    
    $indexInput = @{
        Timestamp = $timestamp
        UserCount = $collectionResult.UserCount
        BlobName = $collectionResult.BlobName
        Summary = $collectionResult.Summary
        CosmosDocumentId = $timestamp
    }
    
    $indexResult = Invoke-DurableActivity `
        -FunctionName 'IndexInCosmosDB' `
        -Input $indexInput
    
    if (-not $indexResult.Success) {
        Write-Warning "Cosmos DB indexing failed: $($indexResult.Error)"
        # Don't fail entire orchestration - we have data in Blob
    }
    else {
        Write-Verbose "Indexing complete:"
        Write-Verbose "  Total users: $($indexResult.TotalUsers)"
        Write-Verbose "  New: $($indexResult.NewUsers)"
        Write-Verbose "  Modified: $($indexResult.ModifiedUsers)"
        Write-Verbose "  Deleted: $($indexResult.DeletedUsers)"
        Write-Verbose "  Unchanged: $($indexResult.UnchangedUsers)"
        Write-Verbose "  Cosmos writes: $($indexResult.CosmosWriteCount)"
    }
    #endregion
    
    #region Step 3: Test AI Foundry (Optional)
    Write-Verbose "Step 3: Testing AI Foundry connectivity..."
    
    $aiTestInput = @{
        Timestamp = $timestamp
        UserCount = $collectionResult.UserCount
        BlobName = $collectionResult.BlobName
        CosmosDocumentId = $timestamp
        DeltaSummary = @{
            NewUsers = $indexResult.NewUsers
            ModifiedUsers = $indexResult.ModifiedUsers
            DeletedUsers = $indexResult.DeletedUsers
        }
    }
    
    $aiTestResult = Invoke-DurableActivity `
        -FunctionName 'TestAIFoundry' `
        -Input $aiTestInput
    
    if ($aiTestResult.Success) {
        Write-Verbose "AI Foundry test successful"
        if ($aiTestResult.AIResponse) {
            Write-Verbose "AI Response: $($aiTestResult.AIResponse)"
        }
    }
    else {
        Write-Verbose "AI Foundry test skipped or failed (non-critical)"
    }
    #endregion
    
    #region Build Final Result
    $finalResult = @{
        OrchestrationId = $Context.InstanceId
        Timestamp = $timestampFormatted
        Status = 'Completed'
        
        Collection = @{
            Success = $collectionResult.Success
            UserCount = $collectionResult.UserCount
            BlobPath = $collectionResult.BlobName
            Duration = "2-3 minutes"
        }
        
        Indexing = @{
            Success = $indexResult.Success
            TotalUsers = $indexResult.TotalUsers
            Changes = @{
                New = $indexResult.NewUsers
                Modified = $indexResult.ModifiedUsers
                Deleted = $indexResult.DeletedUsers
                Unchanged = $indexResult.UnchangedUsers
            }
            CosmosWrites = $indexResult.CosmosWriteCount
            CosmosWriteReduction = if ($indexResult.TotalUsers -gt 0) {
                [math]::Round((1 - ($indexResult.CosmosWriteCount / $indexResult.TotalUsers)) * 100, 2)
            } else { 0 }
        }
        
        AIFoundry = @{
            Success = $aiTestResult.Success
            Message = $aiTestResult.Message
            AIResponse = if ($aiTestResult.AIResponse) { $aiTestResult.AIResponse } else { $null }
        }
        
        Summary = @{
            TotalUsers = $collectionResult.UserCount
            NewUsers = $indexResult.NewUsers
            ModifiedUsers = $indexResult.ModifiedUsers
            DeletedUsers = $indexResult.DeletedUsers
            UnchangedUsers = $indexResult.UnchangedUsers
            DataInBlob = $true
            DataInCosmos = $indexResult.Success
            WriteEfficiency = "$($indexResult.CosmosWriteCount) writes instead of $($indexResult.TotalUsers) ($(100 - [math]::Round(($indexResult.CosmosWriteCount / $indexResult.TotalUsers) * 100, 2))% reduction)"
        }
    }
    
    Write-Verbose "Orchestration complete successfully"
    Write-Verbose "Write efficiency: $($finalResult.Indexing.CosmosWriteReduction)% reduction"
    
    return $finalResult
    #endregion
}
catch {
    Write-Error "Orchestration failed: $_"
    
    return @{
        OrchestrationId = $Context.InstanceId
        Status = 'Failed'
        Error = $_.Exception.Message
        StackTrace = $_.ScriptStackTrace
    }
}


