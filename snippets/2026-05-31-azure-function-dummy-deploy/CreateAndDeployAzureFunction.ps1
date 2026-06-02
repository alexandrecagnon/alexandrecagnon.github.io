#Requires -version 7.0
<#
.SYNOPSIS
    Creates a local Python HTTP Azure Function and deploys it to Azure.

.DESCRIPTION
    Scaffolds the local project, creates a Python virtual environment, provisions Azure resources,
    writes .funcignore, and publishes to a Flex Consumption Function App.

    Pass standardised parameter values from NewAzureFunctionDeployParams.ps1 output.

    REQUIRED PARAMETERS:
    - --ProjectRootDir: full path to the project root directory (created by this script; case preserved)
    - --FunctionProjectDir: directory name for the Function App project inside ProjectRootDir
    - --Location: Azure region (for example southeastasia)
    - --ResourceGroupName: resource group for the Function App
    - --StorageAccountName: storage account name (globally unique)
    - --ManagedIdentityName: user-assigned managed identity for storage access
    - --FunctionAppName: Function App name (globally unique)
    - --PythonVersion: Azure Functions runtime version (major.minor, for example 3.13)
    - --PyVer: pyenv Python version for local .venv (major.minor.patch, for example 3.13.10)
    - --FunctionName: HTTP trigger function name (valid Python identifier; underscores, no hyphens)
    - --HttpsOnly: enforce HTTPS only on the Function App (true or false)
    - --InstanceMemory: Flex Consumption instance memory in MB (512, 1024, or 2048)
    - --Tags: space-separated Azure resource tags as tagName=value (case preserved; empty for no tags)
    - --DeactivateApplicationInsights: remove Application Insights app settings instead of configuring them (true or false, default false)

    OUTCOMES:
    - Success: prints "success: local function created and deployed to Azure" with the Function App URL.
    - Failure: prints "failure: Azure Function setup and deploy" followed by the failing step and exit code.

.EXAMPLE
    COMMAND (parameters from NewAzureFunctionDeployParams.ps1 output):
    .\CreateAndDeployAzureFunction.ps1 `
        --ProjectRootDir "C:\projects\order_func" `
        --FunctionProjectDir "order_function_pre" `
        --Location "southeastasia" `
        --ResourceGroupName "order-func-pre-rg" `
        --StorageAccountName "orderpreseasa01" `
        --ManagedIdentityName "order-func-pre-identity" `
        --FunctionAppName "order-func-pre-sea" `
        --PythonVersion "3.13" `
        --PyVer "3.13.12" `
        --FunctionName "order_http_pre" `
        --HttpsOnly "true" `
        --InstanceMemory "512" `
        --Tags "Environment=Demo Owner=DevTeam" `
        --DeactivateApplicationInsights "false"
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-CliArgs {
    param(
        [string[]]$RawArgs,
        [string[]]$PreserveCaseNames = @()
    )

    $preserveCase = @{}
    foreach ($entry in $PreserveCaseNames) {
        $preserveCase[$entry.ToLowerInvariant()] = $true
    }

    $parsed = [ordered]@{}
    for ($i = 0; $i -lt $RawArgs.Count; $i++) {
        $token = $RawArgs[$i]
        if ($token -notmatch '^--(.+)$') {
            throw "Unexpected argument '$token'. Use --name value pairs (for example --Location southeastasia)."
        }

        $name = $Matches[1]
        if ($i + 1 -ge $RawArgs.Count) {
            throw "Missing value for --$name."
        }

        $value = $RawArgs[$i + 1]
        if ($value -match '^--') {
            throw "Missing value for --$name."
        }

        $key = $name.ToLowerInvariant()
        if ($parsed.Contains($key)) {
            throw "Duplicate argument --$name."
        }

        if ($preserveCase.ContainsKey($key)) {
            $parsed[$key] = $value
        }
        else {
            $parsed[$key] = $value.ToLowerInvariant()
        }
        $i++
    }

    return $parsed
}

function Get-RequiredCliArg {
    param(
        [System.Collections.Specialized.OrderedDictionary]$ArgsMap,
        [string]$Name
    )

    $key = $Name.ToLowerInvariant()
    if (-not $ArgsMap.Contains($key)) {
        throw "Missing required argument --$Name."
    }

    return [string]$ArgsMap[$key]
}

function Get-OptionalCliArg {
    param(
        [System.Collections.Specialized.OrderedDictionary]$ArgsMap,
        [string]$Name,
        [string]$Default
    )

    $key = $Name.ToLowerInvariant()
    if (-not $ArgsMap.Contains($key)) {
        return $Default
    }

    return [string]$ArgsMap[$key]
}

function Invoke-Step {
    param(
        [string]$Label,
        [scriptblock]$Action
    )
    Write-Host ":: [Step] :: $Label"
    & $Action
    if ($LASTEXITCODE -ne 0) { throw "failed command: $Label (exit code $LASTEXITCODE)" }
}

function Test-AzureResourceNamesAvailable {
    param(
        [string]$ResourceGroupName,
        [string]$StorageAccountName,
        [string]$ManagedIdentityName,
        [string]$FunctionAppName
    )

    $existing = [System.Collections.Generic.List[string]]::new()

    $rgExists = az group exists --name $ResourceGroupName -o tsv
    if ($LASTEXITCODE -ne 0) {
        throw "failed command: check resource group existence (exit code $LASTEXITCODE)"
    }
    if ($rgExists -eq 'true') {
        $existing.Add("resource group '$ResourceGroupName'")
    }

    $storageNameAvailable = az storage account check-name --name $StorageAccountName --query nameAvailable -o tsv
    if ($LASTEXITCODE -ne 0) {
        throw "failed command: check storage account name availability (exit code $LASTEXITCODE)"
    }
    if ($storageNameAvailable -eq 'false') {
        $existing.Add("storage account '$StorageAccountName'")
    }

    if ($rgExists -eq 'true') {
        $null = az identity show --name $ManagedIdentityName --resource-group $ResourceGroupName -o none 2>$null
        if ($LASTEXITCODE -eq 0) {
            $existing.Add("managed identity '$ManagedIdentityName' in resource group '$ResourceGroupName'")
        }
        $LASTEXITCODE = 0
    }

    $functionAppId = az resource list `
        --name $FunctionAppName `
        --resource-type Microsoft.Web/sites `
        --query "[0].id" `
        -o tsv
    if ($LASTEXITCODE -ne 0) {
        throw "failed command: check function app name availability (exit code $LASTEXITCODE)"
    }
    if ($functionAppId) {
        $existing.Add("function app '$FunctionAppName'")
    }

    if ($existing.Count -gt 0) {
        $resourceList = $existing -join '; '
        throw "Azure resource(s) already exist: $resourceList. Aborting before local or Azure setup."
    }
}

function Confirm-OverwriteFunctionProject {
    param([string]$ProjectPath)

    if (-not (Test-Path -LiteralPath $ProjectPath)) {
        return
    }

    Write-Host "Function project directory already exists: $ProjectPath"
    $answer = Read-Host 'Overwrite existing directory? [y/N]'
    if ($answer -match '^[yY]$') {
        Remove-Item -LiteralPath $ProjectPath -Recurse -Force
        Write-Host "Removed existing directory."
        return
    }

    throw 'Aborted: existing function project directory was not overwritten.'
}

function New-PythonVenv {
    param(
        [string]$ProjectDir,
        [string]$PyVer
    )

    if (-not (Test-Path -LiteralPath $ProjectDir)) {
        throw "Function project directory not found: $ProjectDir"
    }

    Set-Location -LiteralPath $ProjectDir

    Invoke-Step "pyenv install $PyVer" { pyenv install $PyVer }
    Invoke-Step "pyenv local $PyVer" { pyenv local $PyVer }
    Invoke-Step "create .venv" { pyenv exec python -m venv .venv }
    Invoke-Step "activate .venv" { . .\.venv\Scripts\Activate.ps1 }
    Invoke-Step "upgrade pip" { python -m pip install --upgrade pip setuptools wheel }
    Invoke-Step "install requirements.txt" { pip install -r requirements.txt }
    Write-Host "success creating .venv"
}

$LASTEXITCODE = 0

$FuncIgnore = @"
__pycache__/
.venv/
.vscode/
azurite/
.git/
.gitignore
.python-version
local.settings.json
"@

$OriginalLocation = $null

try {
    $cli = Resolve-CliArgs -RawArgs $args -PreserveCaseNames @('ProjectRootDir', 'Tags')

    $ProjectRootDir = Get-RequiredCliArg -ArgsMap $cli -Name 'ProjectRootDir'
    $FunctionProjectDir = Get-RequiredCliArg -ArgsMap $cli -Name 'FunctionProjectDir'
    $Location = Get-RequiredCliArg -ArgsMap $cli -Name 'Location'
    $ResourceGroupName = Get-RequiredCliArg -ArgsMap $cli -Name 'ResourceGroupName'
    $StorageAccountName = Get-RequiredCliArg -ArgsMap $cli -Name 'StorageAccountName'
    $ManagedIdentityName = Get-RequiredCliArg -ArgsMap $cli -Name 'ManagedIdentityName'
    $FunctionAppName = Get-RequiredCliArg -ArgsMap $cli -Name 'FunctionAppName'
    $PythonVersion = Get-RequiredCliArg -ArgsMap $cli -Name 'PythonVersion'
    $PyVer = Get-RequiredCliArg -ArgsMap $cli -Name 'PyVer'
    $FunctionName = Get-RequiredCliArg -ArgsMap $cli -Name 'FunctionName'
    $HttpsOnly = Get-RequiredCliArg -ArgsMap $cli -Name 'HttpsOnly'
    $InstanceMemory = Get-RequiredCliArg -ArgsMap $cli -Name 'InstanceMemory'
    $Tags = Get-RequiredCliArg -ArgsMap $cli -Name 'Tags'
    $DeactivateApplicationInsights = Get-OptionalCliArg -ArgsMap $cli -Name 'DeactivateApplicationInsights' -Default 'false'

    if ($HttpsOnly -notin @('true', 'false')) {
        throw "Invalid --HttpsOnly '$HttpsOnly'. Allowed values: true, false."
    }

    if ($InstanceMemory -notin @('512', '1024', '2048')) {
        throw "Invalid --InstanceMemory '$InstanceMemory'. Allowed values: 512, 1024, 2048."
    }

    if ($DeactivateApplicationInsights -notin @('true', 'false')) {
        throw "Invalid --DeactivateApplicationInsights '$DeactivateApplicationInsights'. Allowed values: true, false."
    }

    if ($FunctionName -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
        throw "Invalid --FunctionName '$FunctionName'. Use a valid Python identifier (letters, digits, underscores; no hyphens)."
    }

    if ($Tags.Length -gt 0) {
        foreach ($tag in ($Tags -split '\s+')) {
            if ($tag.Length -eq 0) {
                continue
            }
            if ($tag -notmatch '^[^=]+=.+$') {
                throw "Invalid --Tags '$Tags'. Each tag must be tagName=value (for example Environment=Demo)."
            }
        }
    }

    $tagList = @()
    if ($Tags.Length -gt 0) {
        $tagList = @($Tags -split '\s+' | Where-Object { $_.Length -gt 0 })
    }

    Invoke-Step "check Azure resource names are available" {
        Test-AzureResourceNamesAvailable `
            -ResourceGroupName $ResourceGroupName `
            -StorageAccountName $StorageAccountName `
            -ManagedIdentityName $ManagedIdentityName `
            -FunctionAppName $FunctionAppName
    }

    $OriginalLocation = Get-Location

    Invoke-Step "create project root" {
        New-Item -ItemType Directory -Force -Path $ProjectRootDir | Out-Null
    }

    $functionProjectPath = Join-Path $ProjectRootDir $FunctionProjectDir
    Confirm-OverwriteFunctionProject -ProjectPath $functionProjectPath

    Set-Location -LiteralPath $ProjectRootDir

    Invoke-Step "func init" {
        func init $FunctionProjectDir --worker-runtime python --model V2
    }

    if (-not (Test-Path -LiteralPath $functionProjectPath)) {
        throw "Function project directory was not created: $functionProjectPath"
    }

    try {
        New-PythonVenv -ProjectDir $functionProjectPath -PyVer $PyVer
    }
    catch {
        Write-Host "failure creating .venv"
        throw
    }

    Invoke-Step "create HTTP trigger function" {
        func new --template "Http Trigger" --name "$FunctionName" --authlevel "function" --language python
    }

    Invoke-Step "write .funcignore" {
        Set-Content -Path .funcignore -Value $FuncIgnore -Encoding utf8
    }

    Invoke-Step "create resource group" {
        az group create --name $ResourceGroupName --location $Location
    }

    Invoke-Step "register Microsoft.Storage" {
        az provider register --namespace Microsoft.Storage
    }

    Invoke-Step "create storage account" {
        az storage account create `
            --name $StorageAccountName `
            --location $Location `
            --resource-group $ResourceGroupName `
            --sku Standard_LRS `
            --allow-blob-public-access false `
            --allow-shared-key-access false
    }

    $identityJson = az identity create `
        --name $ManagedIdentityName `
        --resource-group $ResourceGroupName `
        --location $Location `
        --query "{userId:id, principalId:principalId, clientId:clientId}" `
        -o json
    if ($LASTEXITCODE -ne 0) { throw "failed command: create managed identity (exit code $LASTEXITCODE)" }
    $identity = $identityJson | ConvertFrom-Json

    $storageId = az storage account show `
        --resource-group $ResourceGroupName `
        --name $StorageAccountName `
        --query 'id' `
        -o tsv
    if ($LASTEXITCODE -ne 0) { throw "failed command: get storage account id (exit code $LASTEXITCODE)" }

    Invoke-Step "assign Storage Blob Data Owner role" {
        az role assignment create `
            --assignee-object-id $identity.principalId `
            --assignee-principal-type ServicePrincipal `
            --role "Storage Blob Data Owner" `
            --scope $storageId
    }

    Invoke-Step "register Microsoft.Web" {
        az provider register --namespace Microsoft.Web
    }

    Invoke-Step "create function app" {
        $createArgs = @(
            'functionapp', 'create',
            '--resource-group', $ResourceGroupName,
            '--name', $FunctionAppName,
            '--flexconsumption-location', $Location,
            '--runtime', 'python',
            '--runtime-version', $PythonVersion,
            '--storage-account', $StorageAccountName,
            '--deployment-storage-auth-type', 'UserAssignedIdentity',
            '--deployment-storage-auth-value', $ManagedIdentityName,
            '--https-only', $HttpsOnly,
            '--instance-memory', $InstanceMemory
        )
        if ($tagList.Count -gt 0) {
            $createArgs += '--tags'
            $createArgs += $tagList
        }
        az @createArgs
    }

    $clientId = az identity show `
        --name $ManagedIdentityName `
        --resource-group $ResourceGroupName `
        --query 'clientId' `
        -o tsv
    if ($LASTEXITCODE -ne 0) { throw "failed command: get managed identity clientId (exit code $LASTEXITCODE)" }

    if ($DeactivateApplicationInsights -eq 'false') {
        Invoke-Step "configure Application Insights managed identity auth" {
            az functionapp config appsettings set `
                --name $FunctionAppName `
                --resource-group $ResourceGroupName `
                --settings "APPLICATIONINSIGHTS_AUTHENTICATION_STRING=ClientId=$clientId;Authorization=AAD"
        }
    }
    else {
        Invoke-Step "deactivate Application Insights" {
            az functionapp config appsettings delete `
                --name $FunctionAppName `
                --resource-group $ResourceGroupName `
                --setting-names APPLICATIONINSIGHTS_AUTHENTICATION_STRING APPLICATIONINSIGHTS_CONNECTION_STRING
        }
    }

    Invoke-Step "configure AzureWebJobsStorage managed identity" {
        az functionapp config appsettings set `
            --name $FunctionAppName `
            --resource-group $ResourceGroupName `
            --settings `
                "AzureWebJobsStorage__accountName=$StorageAccountName" `
                "AzureWebJobsStorage__credential=managedidentity" `
                "AzureWebJobsStorage__clientId=$clientId"
    }

    Invoke-Step "remove AzureWebJobsStorage connection string" {
        az functionapp config appsettings delete `
            --name $FunctionAppName `
            --resource-group $ResourceGroupName `
            --setting-names AzureWebJobsStorage
    }

    Invoke-Step "publish function app to Azure" {
        func azure functionapp publish $FunctionAppName
    }

    Write-Host "success: local function created and deployed to Azure"
    Write-Host "Function App: https://$FunctionAppName.azurewebsites.net"
    Write-Host "Project path: $functionProjectPath"
}
catch {
    Write-Host "failure: Azure Function setup and deploy"
    Write-Host $_.Exception.Message
    exit 1
}
finally {
    if ($null -ne $OriginalLocation) { Set-Location $OriginalLocation }
    Remove-Variable FuncIgnore, identity, identityJson, storageId, clientId, OriginalLocation -ErrorAction SilentlyContinue
    Remove-Item function:Invoke-Step, function:Test-AzureResourceNamesAvailable, function:Confirm-OverwriteFunctionProject, function:New-PythonVenv -ErrorAction SilentlyContinue
}
