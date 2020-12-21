Param (

    [string] $RunbookName,
    [string] $AutomationAccountName,
    [string] $ResourceGroupName,
	[string] $ScriptPath
)


Set-StrictMode -Version 3

Import-AzureRMAutomationRunbook -Name $RunbookName -Path $ScriptPath -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Type PowerShell -Force 

Publish-AzureRmAutomationRunbook -AutomationAccountName $AutomationAccountName -Name $RunbookName -ResourceGroupName $ResourceGroupName