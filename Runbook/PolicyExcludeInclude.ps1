param
(
    [Parameter(Mandatory, Position = 0)]
    [string] $clientID,
    [Parameter(Mandatory, Position = 1)]
    [string] $clientSecret,
    [Parameter(Mandatory, Position = 2)]
    [string] $OperationType,
    [Parameter(Mandatory, Position = 3)]
    [string] $PolicyResourceGroup,
    [Parameter(Mandatory, Position = 4)]
    [string] $PolicySubscriptionId
    
)
 
 $tenant ="ea80952e-a476-42d4-aaf4-5457852b0f7e"
		
 #**********Log In*******************#
 $SecurePwd = $clientSecret | ConvertTo-SecureString -AsPlainText -Force
 $cred = new-object -typename System.Management.Automation.PSCredential -argumentlist $clientID, $SecurePwd
 Connect-AzureRmAccount -Credential $cred -ServicePrincipal -TenantId $tenant

 Select-AzureRmSubscription -SubscriptionID $PolicySubscriptionId

 function PolicyExclusionInclusion([String] $Type)
 {
    $nsfinal   = @()
    $currentns = @()
    $addns     = @()
    
    if($Type -ne $null -or $Type -ne "")    
    {  
        $pa = (Get-AzureRmPolicyAssignment | select PolicyAssignmentId -ExpandProperty properties | where displayname -eq "[Tenant] Govern Automation account").PolicyAssignmentId 
        if ($pa -ne $null)
        {          
            if($Type -eq "Exclude")        
            {
                Write-Output "Adding exclusion"
                $addns = (Get-AzureRmResourceGroup | where ResourceGroupName -eq $PolicyResourceGroup).ResourceId
                $currentns = (Get-AzureRmPolicyAssignment -Id $pa | Select -ExpandProperty properties).notscopes                 
                $nsfinal = $currentns + $addns

                Set-AzureRmPolicyAssignment -Id $pa -NotScope $nsfinal                 
            }
            if($Type -eq "Include")
            {
                Write-Output "Removing Exclusion"
                $removens = (Get-AzureRMResourceGroup | where ResourceGroupName -eq $PolicyResourceGroup).ResourceId
                $currentns = (Get-AzureRmPolicyAssignment -Id $pa | Select -ExpandProperty properties).notscopes
                $nsfinal = $removens | Where-Object { $currentns -notcontains $_}

                if ($nsfinal.Length > 0)
                {
                    Write-Output "Set remaining exclusions"                    
                    Set-AzureRmPolicyAssignment -Id $pa -NotScope $nsfinal
                }
                else
                {
                    Write-Output "Set exclusions empty"
                    Set-AzureRmPolicyAssignment -Id $pa
                }
            } 
        }
    }
    else
    { 
      Write-Output "Exclusion/Inclusion Type can not be null"
    }
 }

 PolicyExclusionInclusion -Type $OperationType