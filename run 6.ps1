#region Timer Trigger Function
<#
This timer trigger automatically starts the orchestrator function on a schedule.
Default schedule: Every 6 hours (0 0 */6 * * * in CRON format)
This allows multiple data collections per day with ISO 8601 timestamps.

Schedule format: "second minute hour day month dayOfWeek"
Examples:
- "0 0 */6 * * *" = Every 6 hours
- "0 0 */4 * * *" = Every 4 hours
- "0 0 0,6,12,18 * * *" = At midnight, 6am, noon, and 6pm
- "0 0 2 * * *" = Daily at 2:00 AM UTC

Modify the schedule in function.json to change timing.
#>
#endregion

param($Timer)

#region Function Logic
try {
    Write-Verbose "Timer trigger activated - starting orchestrator"
    $currentTime = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    Write-Verbose "Current time (UTC): $currentTime"
    
    $InstanceId = Start-DurableOrchestration -FunctionName 'Orchestrator'
    Write-Verbose "Started orchestration with instance ID: $InstanceId"
    
    Write-Verbose "Orchestration started successfully"
    
} catch {
    Write-Error "Failed to start orchestration from timer: $_"
    throw
}
#endregion
