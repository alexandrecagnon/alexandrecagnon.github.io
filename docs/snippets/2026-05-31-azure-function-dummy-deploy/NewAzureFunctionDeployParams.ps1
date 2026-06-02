#Requires -version 7.0
<#
.SYNOPSIS
    Builds standardised deploy-script parameters from Azure Function App creation and deployment.

.DESCRIPTION
    This script validates input parameters and builds standardised deployment parameters for Azure Function Apps
    across DEV, UAT, PRE, and PROD environments using a consistent naming convention.

    INPUT PARAMETERS:
    - --project-root-dir: full path to the project root directory (must exist; case preserved)
    - --product-name: product name (at most 7 characters, letters and digits only, normalised to lowercase)
    - --env: environment (dev, uat, pre, prod, normalised to lowercase)
    - --region-name: Azure region (lowercase Azure region id, must exist in locals.geo_codes.tf.json, e.g. southeastasia)
    - --instance-nbr: instance number (two digits, e.g. 01)
    - --python-version: Python version ( x and yy in x.yy.zz, must match 3.10 ≤ version ≤ 3.13, e.g. 3.13.10)
    - --https-only: enforce HTTPS only on the Function App (true or false, default true)
    - --instance-memory: Flex Consumption instance memory in MB (512, 1024, or 2048, default 512)
    - --tags: space-separated Azure resource tags as tagName=value (case preserved; omit for no tags)
    - --deactivate-application-insights: remove Application Insights app settings instead of configuring them (true or false, default false)

.EXAMPLE
    COMMAND:
    .\NewAzureFunctionDeployParams.ps1 `
        --project-root-dir "C:\projects" `
        --product-name order `
        --env pre `
        --region-name southeastasia `
        --instance-nbr 01 `
        --python-version 3.13.10 `
        --https-only true `
        --instance-memory 512 `
        --tags "Environment=Demo Owner=DevTeam" `
        --deactivate-application-insights false

    OUTPUT:
        --ProjectRootDir "C:\projects\order_func_pre"
        --FunctionProjectDir "order-function"
        --Location "southeastasia"
        --ResourceGroupName "order-func-pre-rg"
        --StorageAccountName "orderpresea01"
        --ManagedIdentityName "order-func-pre-identity"
        --FunctionAppName "order-func-pre-sea"
        --PythonVersion "3.13"
        --PyVer "3.13.10"
        --FunctionName "order_http_pre"
        --HttpsOnly "true" 
        --InstanceMemory "512" 
        --Tags ""
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
            throw "Unexpected argument '$token'. Use --name value pairs (for example --env pre)."
        }

        $name = $Matches[1]
        if ($i + 1 -ge $RawArgs.Count) {
            throw "Missing value for --$name."
        }

        $value = $RawArgs[$i + 1]
        if ($value -match '^--') {
            throw "Missing value for --$name."
        }

        if ($parsed.Contains($name)) {
            throw "Duplicate argument --$name."
        }

        if ($preserveCase.ContainsKey($name.ToLowerInvariant())) {
            $parsed[$name] = $value
        }
        else {
            $parsed[$name] = $value.ToLowerInvariant()
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

    if (-not $ArgsMap.Contains($Name)) {
        throw "Missing required argument --$Name."
    }

    return [string]$ArgsMap[$Name]
}

function Get-OptionalCliArg {
    param(
        [System.Collections.Specialized.OrderedDictionary]$ArgsMap,
        [string]$Name,
        [string]$Default
    )

    if (-not $ArgsMap.Contains($Name)) {
        return $Default
    }

    return [string]$ArgsMap[$Name]
}

function Test-AllowedEnv {
    param([string]$EnvName)

    $allowed = @('dev', 'uat', 'pre', 'prod')
    if ($EnvName -notin $allowed) {
        throw "Invalid --env '$EnvName'. Allowed values: $($allowed -join ', ')."
    }
}

function Test-ProductName {
    param([string]$ProductName)

    if ($ProductName.Length -eq 0) {
        throw 'Product name must not be empty.'
    }

    if ($ProductName.Length -gt 7) {
        throw "Invalid --product-name '$ProductName'. Maximum length is 7 characters."
    }

    if ($ProductName -notmatch '^[A-Za-z0-9]+$') {
        throw "Invalid --product-name '$ProductName'. Use letters and digits only."
    }
}

function Test-PythonVersion {
    param([string]$PythonVersion)

    if ($PythonVersion -notmatch '^(?<major>3)\.(?<minor>10|11|12|13)\.(?<patch>\d+)$') {
        throw "Invalid --python-version '$PythonVersion'. Expected x.yy.zz with 3.10 <= version <= 3.13 (for example 3.13.10)."
    }
}

function Test-InstanceNumber {
    param([string]$InstanceNumber)

    if ($InstanceNumber -notmatch '^\d{2}$') {
        throw "Invalid --instance-nbr '$InstanceNumber'. Expected a two-digit value (for example 01)."
    }
}

function Get-RegionGeoCodeMap {
    param([string]$RegionsFilePath)

    if (-not (Test-Path -LiteralPath $RegionsFilePath)) {
        throw "Regions file not found: $RegionsFilePath"
    }

    $json = Get-Content -LiteralPath $RegionsFilePath -Raw | ConvertFrom-Json
    $geoCodes = $json.locals.builtin_azure_backup_geo_codes
    $map = @{}

    foreach ($property in $geoCodes.PSObject.Properties) {
        if ($property.Name -cmatch '\s') {
            continue
        }

        $map[$property.Name.ToLowerInvariant()] = [string]$property.Value
    }

    return $map
}

function Test-RegionName {
    param(
        [string]$RegionName,
        [hashtable]$RegionGeoCodeMap
    )

    $normalised = $RegionName.ToLowerInvariant()
    if (-not $RegionGeoCodeMap.ContainsKey($normalised)) {
        throw "Invalid --region-name '$RegionName'. Region is not listed in locals.geo_codes.tf.json."
    }
}

function Test-HttpsOnly {
    param([string]$HttpsOnly)

    if ($HttpsOnly -notin @('true', 'false')) {
        throw "Invalid --https-only '$HttpsOnly'. Allowed values: true, false."
    }
}

function Test-InstanceMemory {
    param([string]$InstanceMemory)

    if ($InstanceMemory -notin @('512', '1024', '2048')) {
        throw "Invalid --instance-memory '$InstanceMemory'. Allowed values: 512, 1024, 2048."
    }
}

function Test-DeactivateApplicationInsights {
    param([string]$DeactivateApplicationInsights)

    if ($DeactivateApplicationInsights -notin @('true', 'false')) {
        throw "Invalid --deactivate-application-insights '$DeactivateApplicationInsights'. Allowed values: true, false."
    }
}

function Test-FunctionName {
    param([string]$FunctionName)

    if ($FunctionName -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
        throw "Invalid function name '$FunctionName'. Use a valid Python identifier (letters, digits, underscores; no hyphens)."
    }
}

function Test-Tags {
    param([string]$Tags)

    if ($Tags.Length -eq 0) {
        return
    }

    foreach ($tag in ($Tags -split '\s+')) {
        if ($tag -notmatch '^[^=]+=.+$') {
            throw "Invalid --tags '$Tags'. Each tag must be tagName=value (for example Environment=Demo)."
        }
    }
}

try {
    $cli = Resolve-CliArgs -RawArgs $args -PreserveCaseNames @('project-root-dir', 'tags')

    $projectRootParent = Get-RequiredCliArg -ArgsMap $cli -Name 'project-root-dir'
    $productName = Get-RequiredCliArg -ArgsMap $cli -Name 'product-name'
    $envName = Get-RequiredCliArg -ArgsMap $cli -Name 'env'
    $regionName = Get-RequiredCliArg -ArgsMap $cli -Name 'region-name'
    $instanceNumber = Get-RequiredCliArg -ArgsMap $cli -Name 'instance-nbr'
    $pythonVersionFull = Get-RequiredCliArg -ArgsMap $cli -Name 'python-version'
    $httpsOnly = Get-OptionalCliArg -ArgsMap $cli -Name 'https-only' -Default 'true'
    $instanceMemory = Get-OptionalCliArg -ArgsMap $cli -Name 'instance-memory' -Default '512'
    $tags = Get-OptionalCliArg -ArgsMap $cli -Name 'tags' -Default ''
    $deactivateApplicationInsights = Get-OptionalCliArg -ArgsMap $cli -Name 'deactivate-application-insights' -Default 'false'

    Test-AllowedEnv -EnvName $envName
    Test-ProductName -ProductName $productName
    Test-PythonVersion -PythonVersion $pythonVersionFull
    Test-InstanceNumber -InstanceNumber $instanceNumber
    Test-HttpsOnly -HttpsOnly $httpsOnly
    Test-InstanceMemory -InstanceMemory $instanceMemory
    Test-DeactivateApplicationInsights -DeactivateApplicationInsights $deactivateApplicationInsights
    Test-Tags -Tags $tags

    if (-not (Test-Path -LiteralPath $projectRootParent)) {
        throw "Invalid --project-root-dir '$projectRootParent'. Path does not exist."
    }

    $regionsFile = Join-Path $PSScriptRoot 'locals.geo_codes.tf.json'
    $regionGeoCodeMap = Get-RegionGeoCodeMap -RegionsFilePath $regionsFile
    Test-RegionName -RegionName $regionName -RegionGeoCodeMap $regionGeoCodeMap

    $regionCode = $regionGeoCodeMap[$regionName]
    $pythonMajorMinor = ($pythonVersionFull -split '\.', 3)[0..1] -join '.'

    $projectRootDir = Join-Path $projectRootParent "${productName}_func"
    $functionProjectDir = "${productName}_function_${envName}"
    $resourceGroupName = "${productName}-func-${envName}-rg"
    $storageAccountName = "${productName}${envName}${regionCode}sa${instanceNumber}"
    $managedIdentityName = "${productName}-func-${envName}-identity"
    $functionAppName = "${productName}-func-${envName}-${regionCode}"
    $functionName = "${productName}_http_${envName}"

    Test-FunctionName -FunctionName $functionName

    if ($storageAccountName.Length -lt 3 -or $storageAccountName.Length -gt 24) {
        throw "Generated storage account name '$storageAccountName' is $($storageAccountName.Length) characters. Azure requires 3-24 characters."
    }

    $outputParams = [ordered]@{
        ProjectRootDir      = $projectRootDir
        FunctionProjectDir  = $functionProjectDir
        Location            = $regionName
        ResourceGroupName   = $resourceGroupName
        StorageAccountName  = $storageAccountName
        ManagedIdentityName = $managedIdentityName
        FunctionAppName     = $functionAppName
        PythonVersion       = $pythonMajorMinor
        PyVer               = $pythonVersionFull
        FunctionName        = $functionName
        HttpsOnly           = $httpsOnly
        InstanceMemory              = $instanceMemory
        Tags                        = $tags
        DeactivateApplicationInsights = $deactivateApplicationInsights
    }

    $oneLiner = ($outputParams.GetEnumerator() | ForEach-Object {
        '--{0} "{1}"' -f $_.Key, ($_.Value -replace '"', '""')
    }) -join ' '

    Write-Output $oneLiner
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}