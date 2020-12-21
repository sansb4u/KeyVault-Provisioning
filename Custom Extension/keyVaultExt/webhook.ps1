[CmdletBinding()]
param()

# For more information on the VSTS Task SDK:
# https://github.com/Microsoft/vsts-task-lib
Trace-VstsEnteringInvocation $MyInvocation
try {
    # Set the working directory.
    $ConnectedService = Get-VstsInput -Name ConnectedServiceName -Require
    $subdetail = Get-VstsEndpoint -Name $ConnectedService -Require
    $SubscriptionName = $subdetail.Data.subscriptionName
    $subscriptionID = $subdetail.Data.SubscriptionId
    $clientID = $subdetail.Auth.Parameters.serviceprincipalid
    $key = $subdetail.Auth.Parameters.serviceprincipalkey
    $tenantid = $subdetail.Auth.Parameters.TenantId
    $SecurePassword = $key | ConvertTo-SecureString -AsPlainText -Force
    $cred = new-object -typename System.Management.Automation.PSCredential -argumentlist $clientID, $SecurePassword
    
    Add-AzureRmAccount -Credential $cred -Tenant $tenantid -ServicePrincipal -SubscriptionId $subscriptionID

    $rsgName = Get-VstsInput -Name rsgName -Require
    #$createNew = Get-VstsInput -Name createNew 
    $features = Get-VstsInput -Name features
    $additionalChar = Get-VstsInput -Name additionalChar
    $vaultName = Get-VstsInput -Name vaultName 
    $type = Get-VstsInput -Name type 

    $KeyNameRequired = Get-VstsInput -Name KeyName
    $KeyNameNotRequired = Get-VstsInput -Name KeyNameNotRequired
    $SecretNameRequired = Get-VstsInput -Name SecretName
    $SecretNameNotRequired = Get-VstsInput -Name SecretNameNotRequired

    $KeyOrSecretName = if ($features.Equals( 'createNew')) { if ($type.Equals( 'Key')) { $KeyNameNotRequired } else { $SecretNameNotRequired } } else { if ($type.Equals('Key')) { $KeyNameRequired } else { $SecretNameRequired } }

    $secretValueRequired = Get-VstsInput -Name secretValue
    $secretValueNotRequired = Get-VstsInput -Name secretValueNotRequired
    $secretValue = if ($features.Equals( 'createNew')) { $secretValueNotRequired } else { $secretValueRequired }
    
    $DeploymentGuid = [guid]::NewGuid()	
    $deploymentName = "KeyVaultDeploy-$DeploymentGuid"

    $requestor = $null
    if ($ENV:SYSTEM_HOSTTYPE -eq "Build") {
        $requestor = $ENV:Build_RequestedForEmail        
    }
    else {
        $requestor = if ($ENV:RELEASE_DEPLOYMENT_REQUESTEDFOREMAIL) { $ENV:RELEASE_DEPLOYMENT_REQUESTEDFOREMAIL } else { $ENV:RELEASE_REQUESTEDFOREMAIL }
    }

    #region usage statistics
    try {
        Install-PackageProvider -Name NuGet -Force -Scope CurrentUser  | out-null
        #INSTALL MODULE IF NOT THERE
        if (!(Get-Module -ListAvailable -Name 'Azure.storage')) {
            Install-Module  Azure.storage -Force -Verbose -Scope CurrentUser -AllowClobber 
        } 
        if (!(Get-Module -ListAvailable -Name 'AzureRmStorageTable' ) -or ((Get-Module -ListAvailable -Name 'AzureRmStorageTable').Version -ne '1.0.0.23')) {
            Install-Module  AzureRmStorageTable -Force -Verbose -Scope CurrentUser -AllowClobber  -RequiredVersion '1.0.0.23'
        }
        #IMPORT MODULE IF NOT THERE
        if (!(Get-Module -Name 'Azure.storage')) {
            Import-Module Azure.storage
        } 
        if (!(Get-Module -Name 'AzureRmStorageTable' ) -or ((Get-Module 'AzureRmStorageTable').Version -ne '1.0.0.23')) {
            Import-Module AzureRmStorageTable -RequiredVersion '1.0.0.23'
        }
        $ExtensionUsageTableName = "ExtensionUsageTable"
        $usageConnectionString = "__usageConnectionString__"
        $usageStorageContext = New-AzureStorageContext -ConnectionString $usageConnectionString
        $table = Get-AzureStorageTable -Table $ExtensionUsageTableName -Context $usageStorageContext -ErrorAction SilentlyContinue -ErrorVariable ev
        if ($ev) {
            Write-Verbose "CREATING TABLE"
            $table = New-AzureStorageTable -Name $ExtensionUsageTableName -Context $usageStorageContext
        }

        $PipelineType = $ENV:SYSTEM_HOSTTYPE
        $ExtensionName = "__extensionName__"
        $ExtensionID = "__extensionID__"
        $ExtensionVersion = "__extensionVersion__"
        $TaskName = "__taskName__"
        $TaskId = "__taskID__"
        $TimeStamp = Get-Date
        $tfcUrl = $ENV:System_TeamFoundationCollectionUri
        $Organization = $tfcUrl.Split('/')[2].split('.')[0]        
        $Project = $ENV:System_TeamProject

        $PartitionKey = $Organization
        $RowKey = [guid]::NewGuid()

        if ($PipelineType -eq "Build") {
            $requestor = $ENV:Build_RequestedForEmail        
            $BuildDeploymentId = $ENV:Build_BuildId
            $DefinitionName = $ENV:Build_DefinitionName 
        }
        else {
            $requestor = if ($ENV:RELEASE_DEPLOYMENT_REQUESTEDFOREMAIL) { $ENV:RELEASE_DEPLOYMENT_REQUESTEDFOREMAIL } else { $ENV:RELEASE_REQUESTEDFOREMAIL }
            $BuildDeploymentId = $ENV:Release_DeploymentID
            $DefinitionName = $ENV:Release_DefinitionName
        }
		
        Add-StorageTableRow  -table $table -partitionKey $PartitionKey -rowKey $RowKey -property @{"Requestor" = $requestor; `
                "ExtensionName" = $ExtensionName; "ExtensionID" = $ExtensionID; "TaskName" = $TaskName; "TaskId" = $TaskId; "TimeStamp" = $TimeStamp; `
                "Organization" = $Organization; "Project" = $Project; "BuildDeploymentId" = $BuildDeploymentId; "DefinitionName" = $DefinitionName; `
                "PipelineType" = $PipelineType; "ExtensionVersion" = $ExtensionVersion
        }  | out-null
        Write-Verbose "Usage Satistics stored"
    }
    catch {
        Write-Verbose "Warning: Usage statistics could not be stored."
        Write-Verbose "Exception Message: $($_.Exception.Message)"
        Write-Verbose "Exception StackTrace: $($_.Exception.StackTrace)"
    }
    #endregion


    if (($rsgName -like '*-ase-rsg*') -or ($rsgName -like '*-net-rsg*') ) {
        Write-Host ("Please choose proper Cloud Environment to create the App Service plan.")
        [Environment]::Exit(1)
    }
    else {    
        
        $webhookurl = "--"
        $subscriptionNameArray = $SubscriptionName.Split('-')
        if ($subscriptionNameArray[0] -eq 'zwe' -or $subscriptionNameArray[0] -eq 'zks') {
            $webhookurl = "https://s2events.azure-automation.net/webhooks?token=d5xWwI5Cr0oRFEn%2bOQRwY%2bbe84WFsHmH5PVKOqJ8I5k%3d"
        }
        elseif ($subscriptionNameArray[0] -eq 'znc' -or $subscriptionNameArray[0] -eq 'zsc' -or $subscriptionNameArray[0] -eq 'zcu' -or $subscriptionNameArray[0] -eq 'zwc') {
            $webhookurl = "https://s5events.azure-automation.net/webhooks?token=SwIC2F2gBCMjqcuj08rdzy777cJR2x3xyVCiKPjcYXE%3d"
        }

        elseif ($SubscriptionName -eq "zne-ess2-n-test-sbc") {
            $webhookurl = "https://137143a0-2b6c-436a-b248-dabebf7ccdff.webhook.ne.azure-automation.net/webhooks?token=Za1rOE7LCFJ21jOaWH9PkIu7lGPWH0e27nZ%2fngAkkic%3d"
        }
        elseif ($subscriptionNameArray[0] -eq 'zne' -or $subscriptionNameArray[0] -eq 'zkw') {
            $webhookurl = "https://s9events.azure-automation.net/webhooks?token=JvcyF3itnrIut1W%2b9%2bJ5JsTu0EEsaW7rFkfS6zBE7T0%3d"
        }
        #Test webhook URL
        if ($SubscriptionName.EndsWith("test-sbc" ) -and ($subscriptionNameArray[1] -eq 'eds1' -or $subscriptionNameArray[1] -eq 'ess2') ) {
            $webhookurl = "https://137143a0-2b6c-436a-b248-dabebf7ccdff.webhook.ne.azure-automation.net/webhooks?token=Za1rOE7LCFJ21jOaWH9PkIu7lGPWH0e27nZ%2fngAkkic%3d"
        }
        #staging webhook URL		
        elseif (($SubscriptionName.Contains("mapstg-sbc") -or $SubscriptionName.Contains("region-sbc")) -and ($SubscriptionName.Contains("eds5") -or $SubscriptionName.Contains("eds6"))) {
            if ($subscriptionNameArray[0] -eq 'zne' -or $subscriptionNameArray[0] -eq 'zkw') {
                $webhookurl = "https://aded4309-e823-49d8-aa5f-fffbff35fb90.webhook.ne.azure-automation.net/webhooks?token=oHLqY7VKFJTcU1aboZIWUW4m0YOAEbnlUhDuELm58TM%3d"
            }
            elseif ($subscriptionNameArray[0] -eq 'zwe' -or $subscriptionNameArray[0] -eq 'zks') {
                $webhookurl = "https://74ad2a85-3ef8-4337-a44c-916244418752.webhook.we.azure-automation.net/webhooks?token=9UKLYO%2ffJfd3OXYZAJAOu2%2fdXBUyl5dBMQU7T4%2bIbQA%3d"
            }
            elseif ($subscriptionNameArray[0] -eq 'znc' -or $subscriptionNameArray[0] -eq 'zwc' -or $subscriptionNameArray[0] -eq 'zcu') {
                $webhookurl = "https://372f8811-d9ce-4976-9ad3-5d3eb2e74532.webhook.eus2.azure-automation.net/webhooks?token=UmbhSoQL7Q0axlXq%2bgdncDD0lLYcpRrMfLggxE0y%2fVg%3d"
            }
            elseif ($subscriptionNameArray[0] -eq 'zsc') {
                $webhookurl = "https://b7e51350-efc3-4f3c-a00f-f6757290564f.webhook.scus.azure-automation.net/webhooks?token=d4hwblo07yjiaUsvE1b6S1YFSgTC4gbyPjACO1KJtfQ%3d"
            }
        }
        
        $body = @{"SubscriptionName" = $SubscriptionName; "requestor" = $requestor; "rsgName" = $rsgName; "DeploymentName" = $deploymentName; "features" = $features; "vaultName" = $vaultName; "additionalChar" = $additionalChar ; "type" = $type; "KeyOrSecretName" = $KeyOrSecretName; "secretValue" = $secretValue }

        $params = @{
            ContentType = 'application/json'
            Headers     = @{'from' = 'Vsts'; 'Date' = "$(Get-Date)" }
            Body        = ($body | convertto-json)
            Method      = 'Post'
            URI         = $webhookurl
        }

        $output = Invoke-RestMethod @params -Verbose			
        Write-Host "Output: $output "
        # $output.JobIds.Item(0) 
        $jobId = $output.JobIds

        #Set-AzureRmContext -SubscriptionName $subscriptionID
        Select-AzureRmSubscription -SubscriptionID $subscriptionID

        Write-Host "Deploying Keyvault..."
        $startTime = $(get-date)
        write-host "Elapsed:00:00:00"
        $Event = $true
        While ($Event) {
            $resourceGroupDeployment = Get-AzureRmResourceGroupDeployment -ResourceGroupName $rsgName | Where-Object { $_.DeploymentName -eq $deploymentName }
            $lastDeploymentStatus = $resourceGroupDeployment.ProvisioningState
            Write-Host "deployment Name: $deploymentName" 
            Write-Host "deployment status: $lastDeploymentStatus"
            if ($features -eq "createNew") {
                if ($lastDeploymentStatus -eq "Succeeded" -or $lastDeploymentStatus -eq "Failed") {
                    if ($lastDeploymentStatus -eq "Succeeded") {
                        Write-Host "Deployment '$deploymentName' in Resource Group '$rsgName' successfully completed "
                        $Event = $false                 

                        Write-Host "Output Variables:"

                        # If creating a new key vault, you need to get KVName from deployment details
                       
                        $deploymentdetails = Get-AzureRmResourceGroupDeployment -ResourceGroupName $rsgName -DeploymentName $deploymentName
                        $keyVaultName = $deploymentdetails.Outputs.Values.Value
                        
                        $Token = Invoke-RestMethod -Uri https://login.microsoftonline.com/$tenantid/oauth2/token?api-version=1.0 -Method Post -Body @{"grant_type" = "client_credentials"; "resource" = "https://management.azure.com"; "client_id" = $clientID; "client_secret" = $key}
			            $Headers = ""
			            $Headers = @{
	          			'authorization'="Bearer $($Token.access_token)";	          
                        }
                        
                        $properties=Invoke-RestMethod -Method Get -Uri "https://management.azure.com/subscriptions/$subscriptionID/resourceGroups/$rsgName/providers/Microsoft.KeyVault/vaults/${keyVaultName}?api-version=2019-09-01" -Headers $Headers
                        $keyVaultResourceId = $properties.id

                        # Output key vault name for using in subsequent tasks
                        Write-Host "key vault name: $keyVaultName"
                        Write-Host "##vso[task.setvariable variable=KVName]$keyVaultName"
                        
                        # Output key vault resource id for using in subsequent tasks
                        Write-Host "key vault resource id : $keyVaultResourceId"
                        Write-Host "##vso[task.setvariable variable=KVResourceID]$keyVaultResourceId"

                        if ($type -eq "Key") {
                            #Output key name for using in subsequent tasks
                            Write-Host "key name: $KeyNameNotRequired"
                            Write-Host "##vso[task.setvariable variable=KVKeyName]$KeyNameNotRequired"
                        }
                        else {
                            #Output secret name for using in subsequent tasks
                            Write-Host "secret name: $SecretNameNotRequired"
                            Write-Host "##vso[task.setvariable variable=KVSecretName]$SecretNameNotRequired"
                        }

                        # Output key vault subscription name for using in subsequent tasks
                        Write-Host "key vault subscription name: $SubscriptionName"
                        Write-Host "##vso[task.setvariable variable=KVSubscriptionName]$SubscriptionName"

                        # Output key vault resource group name for using in subsequent tasks
                        Write-Host "key vault resource group name: $rsgName"
                        Write-Host "##vso[task.setvariable variable=KVRSGName]$rsgName"
                    }
                    else {
                        Write-Host "Deployment '$deploymentName' in Resource Group '$rsgName' failed"
                        Write-Host "Keyvault deployment error details: " $resourceGroupDeployment.OutputsString
                        $Event = $false
                    }
                }
                else {
                    Write-Host "Keyvault deployment is in progress"
                    $Event = $true
                }
            }
            else {
                # If creating a key or secret in an existing key vault, output the key / secret name
                
                Write-Host "Deployment '$deploymentName' in Resource Group '$rsgName' successfully completed "

                # Output key vault name for using in subsequent tasks
                Write-Host "Output Variables:"
                Write-Host "key vault name: $vaultName"
                Write-Host "##vso[task.setvariable variable=KVName]$vaultName"
                    
                if ($type -eq "Key") {
                    #Output key name for using in subsequent tasks
                    Write-Host "key name: $KeyNameRequired"
                    Write-Host "##vso[task.setvariable variable=KVKeyName]$KeyNameRequired"
                }
                else {
                    #Output secret name for using in subsequent tasks
                    Write-Host "secret name: $SecretNameRequired"
                    Write-Host "##vso[task.setvariable variable=KVSecretName]$SecretNameRequired"
                }
                
                # Output key vault resource id for using in subsequent tasks
                $Token = Invoke-RestMethod -Uri https://login.microsoftonline.com/$tenantid/oauth2/token?api-version=1.0 -Method Post -Body @{"grant_type" = "client_credentials"; "resource" = "https://management.azure.com"; "client_id" = $clientID; "client_secret" = $key}
			            $Headers = ""
			            $Headers = @{
	          			'authorization'="Bearer $($Token.access_token)";	          
                        }                        
                $properties=Invoke-RestMethod -Method Get -Uri "https://management.azure.com/subscriptions/$subscriptionID/resourceGroups/$rsgName/providers/Microsoft.KeyVault/vaults/${vaultName}?api-version=2019-09-01" -Headers $Headers
                $keyVaultResourceId = $properties.id

                Write-Host "key vault resource id : $keyVaultResourceId"
                Write-Host "##vso[task.setvariable variable=KVResourceID]$keyVaultResourceId"

                # Output key vault subscription name for using in subsequent tasks
                Write-Host "key vault subscription name: $SubscriptionName"
                Write-Host "##vso[task.setvariable variable=KVSubscriptionName]$SubscriptionName"

                # Output key vault resource group name for using in subsequent tasks
                Write-Host "key vault resource group name: $rsgName"
                Write-Host "##vso[task.setvariable variable=KVRSGName]$rsgName"

                $Event = $false

            }
            Start-Sleep -s 15
            $elapsedTime = new-timespan $startTime $(get-date)
            write-host "Elapsed:$($elapsedTime.ToString("hh\:mm\:ss"))" 

        }

    }
}


finally {
    Trace-VstsLeavingInvocation $MyInvocation
}





