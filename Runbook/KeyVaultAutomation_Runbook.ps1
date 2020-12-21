
Param(
    [Parameter (Mandatory = $true)]
    [object]$WebHookData
)
if ($WebHookData) {

    # Collect properties of WebhookData
    $WebhookName = $WebHookData.WebhookName
    $WebhookHeaders = $WebHookData.RequestHeader
    $WebhookBody = $WebHookData.RequestBody

    # Collect individual headers. 
    # Input  converted from JSON.
    $From = $WebhookHeaders.From
    $Input = (ConvertFrom-Json -InputObject $WebhookBody)
    Write-Verbose "WebhookBody: $Input"
    Write-Output -InputObject ('Runbook started from webhook {0} by {1}.' -f $WebhookName, $From)
}
else {
    Write-Error -Message 'Runbook was not started from Webhook' -ErrorAction stop
}

Function SetAcessPolicyToKeyvault([string] $kvName) {
    
    ## access for ServicePrincipal   
    $SPApp = Get-AzurermADServicePrincipal -ServicePrincipalName $ServicePrincipalConnection.ApplicationId
    Set-AzureRmKeyVaultAccessPolicy -VaultName $kvName -ObjectId $SPApp.Id.Guid -PermissionsToKeys $appKeysPermissions -PermissionsToSecrets $appSecretsPermissions -PermissionsToCertificates $appCertPermissions

    # access to requestor
    $i = Get-AzureADUser -ObjectId $requestor
    Set-AzureRmKeyVaultAccessPolicy -VaultName $kvName -ObjectId $i.ObjectId -PermissionsToKeys $requestorKeysPermissions -PermissionsToSecrets $requestorSecretsPermissions -PermissionsToCertificates $requestorCertPermissions

}

Function GetCount([string] $rsgName) {
    $rsg = Get-AzureRmResourceGroup -Name $rsgName
    $kv = Get-AzureRmKeyVault -ResourceGroupName $rsg.resourceGroupName
    if ($kv.count -gt 0) {
        $value = ''
        foreach ($i in $kv) {
            $name = $i.vaultName
            $len = $i.vaultName.length
            $digits = $name.substring($len - 2)
            if ($digits -match '\d\d') {
                if ($digits -gt $value) {
                    $value = $digits
                }    
            }
        }
        if ($value -eq '') {
            $value = '00'
        }
        else {
            $i = [int]$value
            $i += 1
            $value = $i.toString('00')
        }
    }
    else {
        $value = '00'
    }
    return $value
}


Function AddKeyOrSecret([string] $feature, [string] $kvName, [string] $type, [string]$KeyOrSecretName, [string]$secretValue) {
    if ($type.toLower() -eq 'key') {
        $startDate = (Get-Date).AddDays(-1)
        $endDate = $startDate.AddYears(99)
        Add-AzureKeyVaultKey -VaultName $kvName -Name $KeyOrSecretName  -Destination 'software' -Expires $endDate -NotBefore $startDate
        Write-Output "Key: $KeyOrSecretName added to the Key Vault: $kvName"

        $success = $true
        Write-Host "##vso[task.setvariable variable=finished]$success"
    }
    elseif ($type.toLower() -eq 'secret') {
        if ($secretValue.Length -gt 0) {
            write-output " $feature "
            write-output "Secret name is : $KeyOrSecretName ; secret value is : $secretValue"
            Write-output "Converting Secret to secure String."
            $secretSecureString = ConvertTo-SecureString $secretValue -AsPlainText -Force            
            Write-output "Adding secure Secret to Key vault : $secretSecureString "
            Set-AzureKeyVaultSecret -VaultName $kvName -Name $KeyOrSecretName -SecretValue $secretSecureString
        }
        else {
            write-output 'Secret Value field cannot be empy. Please provide a value.'
        }
        
    } 
}

###################################################################################################################################
$SubscriptionName = $Input.SubscriptionName
$rsgName = $Input.rsgName
$features = $Input.features
$vaultName = $Input.vaultName
$additionalChar = $Input.additionalChar
$type = $Input.type
$KeyOrSecretName = $Input.KeyOrSecretName
$secretValue = $Input.secretValue
$requestor = $Input.requestor
$DeploymentName = $Input.DeploymentName

#Requestor access policies to keyvault
$requestorKeysPermissions = @("Decrypt", "Encrypt", "UnwrapKey", "WrapKey", "Verify", "Sign", "Get", "List", "Import", "Backup", "Recover")
$requestorSecretsPermissions = @("get", "list", "Backup", "Restore", "Recover")
$requestorCertPermissions = @("get", "list", "import", "Managecontacts", "Getissuers", "Listissuers")

#Automation account access policies to keyvault
$appKeysPermissions = @("Decrypt", "Encrypt", "UnwrapKey", "WrapKey", "Verify", "Sign", "Get", "List", "Update", "Create", "Import", "Delete", "Backup", "Restore", "Recover", "Purge")
$appSecretsPermissions = @("Get", "List", "Set", "Delete", "Backup", "Restore", "Recover", "Purge")
$appCertPermissions = @("Get", "List", "Delete", "Create", "Import", "Update", "Managecontacts", "Getissuers", "Listissuers", "Setissuers", "Deleteissuers", "Manageissuers")

$ServicePrincipalConnection = Get-AutomationConnection -Name "RunbookAccountConnection"
$tenantId = $ServicePrincipalConnection.TenantId

Add-AzureRmAccount `
    -ServicePrincipal `
    -TenantId $tenantId `
    -ApplicationId $ServicePrincipalConnection.ApplicationId `
    -CertificateThumbprint $ServicePrincipalConnection.CertificateThumbprint | Write-Verbose

Write-Output 'Azure account logged in'

Connect-AzureAD -TenantId $tenantId -ApplicationId $ServicePrincipalConnection.ApplicationId -CertificateThumbprint $ServicePrincipalConnection.CertificateThumbprint  

$requestorObjectId = (Get-AzureADUser -ObjectId $requestor).ObjectId

$hubSubscriptionId = Get-AutomationVariable -Name 'AVMP_HubSubscriptionId'
$templatestorageAccount = Get-AutomationVariable -Name 'AVMP_TemplateStorageAccount'
$templatecontainername = Get-AutomationVariable -Name 'AVMP_TemplateContainerName'
$templateresourcegroup = Get-AutomationVariable -Name 'AVMP_TemplateResourceGroup'

$keyvaultSku = 'Standard'
$keyvaultTemplateContainerName = Get-AutomationVariable -Name 'AVMP_KeyvaultTemplateContainerName'
$keyvaultTemplateFileName = 'KeyVaultDeployment.template.json'
$keyvaultTemplateContainerLocation = $keyvaultTemplateContainerName + '/' + $keyvaultTemplateFileName

Select-AzureRmSubscription -SubscriptionId $hubSubscriptionId
$nowTime = Get-Date
$startTime = $nowTime.AddMinutes(-15.0)
$endTime = $nowTime.AddHours(4.0)

$templateStorage = Get-AzureRmStorageAccount -Name $templatestorageAccount -ResourceGroupName $templateresourcegroup	
$templateStorageCtx = $templateStorage.Context    

#Getting ARM template URI 
$basetempSasToken = New-AzureStorageBlobSASToken -Container $templatecontainername -Blob $keyvaultTemplateContainerLocation -Permission r -StartTime $startTime -ExpiryTime $endTime -Context $templateStorageCtx
$templateFileUri = (Get-AzureStorageContainer -Context $templateStorageCtx -Name $templatecontainername ).CloudBlobContainer.StorageUri.PrimaryUri.ToString() + '/' + $keyvaultTemplateContainerLocation + $basetempSasToken.ToString()
Write-Output "Template file location: $templateFileUri"
### --------------------------------------------------

Set-AzureRmContext -Subscription $SubscriptionName

write-output "Context is : "
Get-AzureRmContext

$rsg = Get-AzureRmResourceGroup -Name $rsgName
$rname = $rsg.ResourceGroupName
$rloc = $rsg.Location

#If new, then Keyvault is being created using ARM in order to get the deployment status
if (($features -eq 'createNew') -or ($features -eq 'createNewFromAppReg')) {
    #Getting count for already existing and deployed keyvaults in resource group
    $count = GetCount -rsgName $rsgName  ## function call
    $tmp = $rsgname.Split('-')
    $tmp2 = $tmp -join ""
    $len = $tmp2.Length
    $kvName = ""
    #restricting the part derived from resource group name to 16 characters
    if ($tmp2.Length -gt 13) {
        $tmp2 = $tmp2.Substring(0, 13)
    }
    if ($additionalChar.Length -gt 5 ) {
        $kvName = $tmp2 + $additionalChar.Substring(0, 5) + '-kvl' + $count
    }
    else {
        if ($additionalChar.Length -gt 0 ) {
            $kvName = $tmp2 + $additionalChar + '-kvl' + $count
        }
        else {
            $kvName = $tmp2 + '-kvl' + $count
        }        
    }
    #removing any special characters other than -
    $kvName = $kvName -replace '[^a-zA-Z0-9-]', ''
	
    #removing consecutive hyphen
    while ($kvName.Contains('--')) {
        $kvName.Replace('--', '-')
    }
    
    $body = ""
    
    try {
        write-output "Creating Key Vault: $kvName in resource group: $rname"

        $KeyVaultDeploymentParameters = @{
            Name                    = $DeploymentName;
            ResourceGroupName       = $rname;
            Mode                    = 'Incremental';
            TemplateFile            = $templatefileuri;
            TemplateParameterObject = @{
                keyVaultName                   = $kvName;
                tenantId                       = $TenantId;
                objectId                       = $requestorObjectID;
                keysPermissions                = $requestorKeysPermissions;
                secretsPermissions             = $requestorSecretsPermissions;
                certPermissions                = $requestorCertPermissions;
                vaultSku                       = $keyvaultSku;
                enabledForDeployment           = $false;
                enabledForTemplateDeployment   = $false;
                enableVaultForVolumeEncryption = $false;
                location                       = $rloc;
            }
        }

        New-AzureRmResourceGroupDeployment @KeyVaultDeploymentParameters -Verbose

        write-output "Key Vault Created: $kvName"
        write-output "In $rname resource group"
        write-output "Key Vault location: $rloc"
        
    }
    catch {
        write-output "Some Error Occured while creating new key vault"
        $body = "error"
        Write-Output $Error[0]
    }
    try {
        #Adding access policies to the requestor and automation account service principle
        SetAcessPolicyToKeyvault -kvName $kvName
    }
    catch {
        write-output "Error occured while adding $requestor to the access policy"
        Write-Output $Error[0]
    }

    try {
        if ($KeyOrSecretName ) {
            #Adding secret or key to keyvault. Not part of the ARM deployment due to limited Keyvault ARM functionality.
            AddKeyOrSecret -feature $features -kvName $kvName -type $type -KeyOrSecretName $KeyOrSecretName -secretValue $secretValue #there is no secret value coming in #BUG#
            write-output "Adding Secret : $secretValue " 
        }

    }
    catch {
        write-output "Error occured while adding a Key or a Secret"
        Write-Output $Error[0]
    }

}
else {
    #If existing keyvault, always execute through the powershell and not ARM due to limited ARM functionality
    $kv = Get-AzureRmKeyVault -ResourceGroupName $rsg.resourceGroupName -vaultName $vaultName
    if ($kv) {
        try {
            #Adding access policies to existing keyvault
            SetAcessPolicyToKeyvault -kvName $vaultName 
        }
        catch {
            write-host 'Policies are already added'
            Write-Output $Error[0]
        }
        try {
            if ($KeyOrSecretName) {
                #Adding key or secret
                AddKeyOrSecret -feature $features -kvName $vaultName -type $type -KeyOrSecretName $KeyOrSecretName -secretValue $secretValue
                write-output "Adding Key : $secretValue "
            }       
        }
        catch {
            $body = "Error occured while adding a Key or a Secret"
            Write-Output $Error[0]
        }
    }
    else {
        write-host "$vaultName doesnot exist. Please try with a different name or create a new one"
    }

}
# checkin





