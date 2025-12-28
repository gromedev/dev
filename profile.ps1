#region Azure Function App Profile
<#
This profile script runs once when the Function App starts.
It sets up the PowerShell environment with managed identity authentication.
#>
#endregion

#region Managed Identity Setup
if ($env:MSI_SECRET) {
    Write-Verbose "Managed Identity detected - configuring authentication"
    Disable-AzContextAutosave -Scope Process | Out-Null
    $AzureContext = (Connect-AzAccount -Identity).context
    Set-AzContext -SubscriptionName $AzureContext.Subscription -DefaultProfile $AzureContext | Out-Null
    Write-Verbose "Successfully authenticated with Managed Identity"
}
#endregion

#region Module Imports
Write-Verbose "Function App profile loaded successfully"
#endregion
