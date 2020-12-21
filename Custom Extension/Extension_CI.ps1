Param (		
	[string] $DigitalFoundationsPATToken,
[string] $ExtensionVersion,
[string] $TaskPatchVersion,
[string] $ExtensionVersionVariableName,
[string] $TaskPatchVersionVariableName,
[string] $varGroupName,
[string] $VarGroupID
)

$extensionVSplit=$ExtensionVersion.split('.')
$extPatch ="$([System.Convert]::ToInt32($extensionVSplit[2]) + 1)"
$extensionNewVersion = $extensionVSplit[0] + "." + $extensionVSplit[1]+"." + $extPatch 
$taskPatch =([System.Convert]::ToInt32($TaskPatchVersion) + 1)


$base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f "","$DigitalFoundationsPATToken")))
$Url = "$env:SYSTEM_TEAMFOUNDATIONCOLLECTIONURI/$env:SYSTEM_TEAMPROJECT/_apis/distributedtask/variablegroups/$VarGroupID`?api-version=5.0-preview.1"

$getJSON = Invoke-RestMethod -Uri $Url -Method Get  -Headers @{Authorization=("Basic {0}" -f $base64AuthInfo)}

$getJSON.variables.$ExtensionVersionVariableName.value = $extensionNewVersion
$getJSON.variables.$TaskPatchVersionVariableName.value  = $taskPatch 

$SetJson= $getJSON.variables |  ConvertTo-Json

$json = '{"id":'+ $VarGroupID+',"type":"Vsts","name":"'+$varGroupName+'","variables":'+ $SetJson+'}}}'

$pipeline = Invoke-RestMethod -Uri $Url  -Method Put -Body $json -ContentType "application/json" -Headers @{Authorization=("Basic {0}" -f $base64AuthInfo)}

write-host " " $pipeline 
Write-Host "Extension Version:" $pipeline.variables.$ExtensionVersionVariableName.value 
Write-Host "Task Patch Version:" $pipeline.variables.$TaskPatchVersionVariableName.value 