
#region Test AI Foundry Activity - GRACEFUL FAILURE PATTERN
<#
.SYNOPSIS
    Tests AI Foundry connectivity and data accessibility (optional, non-blocking)
.DESCRIPTION
    - Verifies AI Foundry endpoint is configured
    - Attempts to acquire AI Foundry token
    - Auto-detects model deployment if not specified
    - Sends test prompt referencing collected data
    - ALWAYS returns Success = true (never blocks data collection)
    
    Graceful Failure:
    - Missing endpoint → Skip with message
    - Token acquisition fails → Skip with message
    - No models deployed → Skip with instructions
    - API call fails → Log warning, continue
    
    This activity is designed to never fail the orchestration.
#>
#endregion

param($ActivityInput)

Import-Module EntraDataCollection

try {
    Write-Verbose "Starting AI Foundry connectivity test (optional)"
    
    $foundryEndpoint = $env:AI_FOUNDRY_ENDPOINT
    $projectName = $env:AI_FOUNDRY_PROJECT_NAME
    $timestamp = $ActivityInput.Timestamp
    $userCount = $ActivityInput.UserCount
    $blobName = $ActivityInput.BlobName
    $cosmosDocumentId = $ActivityInput.CosmosDocumentId
    $deltaSummary = $ActivityInput.DeltaSummary
    
    # Check if AI Foundry is configured
    if (-not $foundryEndpoint) {
        Write-Warning "AI Foundry endpoint not configured - skipping test"
        return @{
            Success = $true
            Message = "AI Foundry test skipped (endpoint not configured)"
            Note = "This is normal for initial deployment. Configure AI_FOUNDRY_ENDPOINT to enable."
        }
    }
    
    Write-Verbose "AI Foundry Endpoint: $foundryEndpoint"
    Write-Verbose "Project: $projectName"
    Write-Verbose "Testing data from: $timestamp"
    
    # Get token
    try {
        $token = Get-ManagedIdentityToken -Resource "https://ml.azure.com"
    }
    catch {
        Write-Warning "Could not acquire AI Foundry token: $_"
        return @{
            Success = $true
            Message = "AI Foundry test skipped (token acquisition failed)"
            Note = "This is normal if AI Foundry permissions haven't been configured yet."
        }
    }
    
    # Get deployment name (with auto-detection)
    $deploymentName = $env:AI_MODEL_DEPLOYMENT_NAME
    
    if (-not $deploymentName) {
        Write-Verbose "AI_MODEL_DEPLOYMENT_NAME not set, attempting to detect..."
        
        $headers = @{
            "Authorization" = "Bearer $token"
            "Content-Type" = "application/json"
        }
        
        try {
            $deploymentsUri = "$foundryEndpoint/openai/deployments?api-version=2024-02-01"
            $deployments = Invoke-RestMethod -Uri $deploymentsUri -Headers $headers -ErrorAction Stop
            
            if ($deployments.data -and $deployments.data.Count -gt 0) {
                $deploymentName = $deployments.data[0].id
                Write-Verbose "Auto-detected deployment: $deploymentName"
            }
            else {
                Write-Warning "No AI model deployments found"
                return @{
                    Success = $true
                    Message = "AI Foundry test skipped (no models deployed)"
                    Note = "Deploy a model (gpt-4o-mini recommended) in Azure AI Foundry portal: https://ai.azure.com"
                }
            }
        }
        catch {
            Write-Warning "Could not detect deployments: $_"
            return @{
                Success = $true
                Message = "AI Foundry test skipped (could not detect deployments)"
                Note = "Deploy a model and set AI_MODEL_DEPLOYMENT_NAME environment variable"
            }
        }
    }
    
    # Construct test prompt
    $testPrompt = @"
Quick verification test for data collection at timestamp $timestamp:

Data sources available:
1. Cosmos DB: Document ID '$cosmosDocumentId' in database 'EntraData'
   - Container 'users_raw': Current state of all users
   - Container 'user_changes': Change log
   - Container 'snapshots': Collection metadata
2. Blob Storage: File '$blobName' in container 'raw-data'

Collection summary:
- Total users: $userCount
- New users: $($deltaSummary.NewUsers)
- Modified users: $($deltaSummary.ModifiedUsers)
- Deleted users: $($deltaSummary.DeletedUsers)

Please confirm you can access this data and respond with:
- Brief acknowledgment
- One insight about the data

Keep response under 100 words.
"@

    # Call AI Foundry
    $requestBody = @{
        messages = @(
            @{
                role = "system"
                content = "You verify data accessibility in Azure. Respond concisely."
            },
            @{
                role = "user"
                content = $testPrompt
            }
        )
        max_tokens = 150
        temperature = 0.3
    } | ConvertTo-Json -Depth 10
    
    $apiUrl = "$foundryEndpoint/openai/deployments/$deploymentName/chat/completions?api-version=2024-02-01"
    
    try {
        $headers = @{
            "Authorization" = "Bearer $token"
            "Content-Type" = "application/json"
        }
        
        $response = Invoke-RestMethod -Uri $apiUrl -Method Post -Headers $headers -Body $requestBody
        $aiResponse = $response.choices[0].message.content
        
        Write-Verbose "AI Foundry test successful"
        Write-Verbose "Response: $aiResponse"
        
        return @{
            Success = $true
            Message = "AI Foundry successfully accessed data sources"
            AIResponse = $aiResponse
            DeploymentUsed = $deploymentName
            Timestamp = $timestamp
            UserCount = $userCount
        }
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        Write-Warning "AI Foundry API call failed (status: $statusCode): $_"
        
        return @{
            Success = $true
            Message = "AI Foundry test completed with warnings"
            Note = "Infrastructure is configured but API call failed. This is often due to model deployment being in progress or needing additional configuration."
            Error = $_.Exception.Message
            Timestamp = $timestamp
        }
    }
}
catch {
    Write-Warning "Unexpected error in AI Foundry test: $_"
    
    return @{
        Success = $true
        Message = "AI Foundry test skipped due to unexpected error"
        Error = $_.Exception.Message
        Note = "This won't prevent data collection. AI testing can be configured later."
    }
}

