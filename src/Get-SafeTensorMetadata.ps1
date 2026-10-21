#Requires -Version 5.1

param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Path,

    [switch]$TensorList,
    [switch]$Hash,

    [ValidateSet('Object', 'Json')]
    [string]$Format = 'Object'
)

if ($PSVersionTable.PSVersion.Major -ge 6 -and $PSVersionTable.PSVersion -lt [version]'7.5') {
    throw 'Use Windows PowerShell 5.1 or PowerShell 7.5 or later.'
}

function ConvertFrom-JsonText {
    param([string]$Text)

    $options = @{ InputObject = $Text; ErrorAction = 'Stop' }
    # PowerShell 7.5+ can preserve date strings instead of converting them.
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        $options.DateKind = 'String'
    }
    ConvertFrom-Json @options
}

function Get-MetadataValue {
    param([string[]]$Names, $Source = $metadata)

    foreach ($name in $Names) {
        if ($null -eq $Source) { return $null }
        $property = $Source.PSObject.Properties[$name]
        if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return $property.Value
        }
    }
    return $null
}

function Get-JsonMetadata {
    param([string]$Name)

    $text = Get-MetadataValue -Names $Name
    if ($null -eq $text) { return $null }
    try {
        if (-not $text.TrimStart().StartsWith('{')) {
            throw 'Expected a JSON object.'
        }
        $value = ConvertFrom-JsonText -Text $text
        if ($value -isnot [System.Management.Automation.PSCustomObject]) {
            throw 'Expected a JSON object.'
        }
        return $value
    }
    catch {
        $warnings.Add("Could not read ${Name}: $($_.Exception.Message)")
        return $null
    }
}

function Get-TrainingTags {
    param([string]$Json)

    if (-not $Json.TrimStart().StartsWith('{')) {
        throw 'Expected a JSON object containing tag groups.'
    }
    if ($PSVersionTable.PSVersion.Major -eq 5) {
        # PowerShell 5.1 has no -AsHashtable option.
        Add-Type -AssemblyName System.Web.Extensions
        $parser = [System.Web.Script.Serialization.JavaScriptSerializer]::new()
        $parser.MaxJsonLength = 100000000
        $groups = $parser.DeserializeObject($Json)
    }
    else {
        $groups = ConvertFrom-Json -InputObject $Json -AsHashtable -ErrorAction Stop
    }

    # Keep tags with different capitalization separate.
    $totals = [System.Collections.Generic.Dictionary[string, long]]::new([System.StringComparer]::Ordinal)
    foreach ($group in $groups.GetEnumerator()) {
        if ($group.Value -isnot [System.Collections.IDictionary]) {
            throw "Tag group '$($group.Key)' must be an object."
        }
        foreach ($tag in $group.Value.GetEnumerator()) {
            $count = [long]0
            if (-not [long]::TryParse([string]$tag.Value, [ref]$count) -or $count -lt 0) {
                throw "Tag '$($tag.Key)' must have a nonnegative integer count."
            }
            if ([string]::IsNullOrWhiteSpace($tag.Key)) { continue }
            if ($totals.ContainsKey($tag.Key)) {
                if ($count -gt ([long]::MaxValue - $totals[$tag.Key])) {
                    throw "Total count for tag '$($tag.Key)' is too large."
                }
                $totals[$tag.Key] += $count
            }
            else {
                $totals.Add($tag.Key, $count)
            }
        }
    }

    $totals.GetEnumerator() |
        Sort-Object @{ Expression = 'Value'; Descending = $true }, Key -CaseSensitive |
        ForEach-Object { [pscustomobject]@{ Tag = $_.Key; Count = $_.Value } }
}

$file = Get-Item -LiteralPath $Path -ErrorAction Stop
if ($null -eq $file) { throw "File not found: $Path" }
$stream = [System.IO.File]::OpenRead($file.FullName)
$reader = [System.IO.BinaryReader]::new($stream)

try {
    if ($stream.Length -lt 8) {
        throw 'The file is too short to contain a SafeTensors header length.'
    }

    # SafeTensors stores the length as little-endian, matching BinaryReader.
    $headerLength = $reader.ReadUInt64()
    if ($headerLength -lt 2 -or $headerLength -gt 100000000) {
        throw "Invalid SafeTensors header length: $headerLength. Expected 2 to 100000000 bytes."
    }
    if ($headerLength -gt ($stream.Length - 8)) {
        throw 'The file ends before the declared SafeTensors header is complete.'
    }

    $headerBytes = $reader.ReadBytes([int]$headerLength)
    if ($headerBytes.Length -ne $headerLength) {
        throw 'The file ends before the declared SafeTensors header is complete.'
    }
    if ($headerBytes[0] -ne 0x7B) {
        throw 'The SafeTensors header must begin with a JSON object.'
    }

    # Reject invalid UTF-8.
    $encoding = [System.Text.UTF8Encoding]::new($false, $true)
    try {
        $headerText = $encoding.GetString($headerBytes)
    }
    catch {
        throw 'The SafeTensors header contains invalid UTF-8.'
    }

    try {
        $header = ConvertFrom-JsonText -Text $headerText
    }
    catch {
        throw 'The SafeTensors header contains invalid JSON.'
    }
}
finally {
    $reader.Dispose()
}

$metadata = [pscustomobject]@{}
$metadataProperty = $header.PSObject.Properties | Where-Object { $_.Name -ceq '__metadata__' }
if ($null -ne $metadataProperty) {
    $metadata = $metadataProperty.Value
    if ($metadata -isnot [System.Management.Automation.PSCustomObject]) {
        throw 'SafeTensors metadata must be a JSON object containing string values.'
    }
    foreach ($property in $metadata.PSObject.Properties) {
        if ($property.Value -isnot [string]) {
            throw "SafeTensors metadata value '$($property.Name)' must be a string."
        }
    }
}

$warnings = [System.Collections.Generic.List[string]]::new()
$trainingInfo = Get-JsonMetadata -Name 'training_info'
$trainingConfig = Get-JsonMetadata -Name 'ot_config'
$softwareName = Get-MetadataValue -Names 'software'
if ($null -ne $softwareName -and $softwareName.TrimStart().StartsWith('{')) {
    $software = Get-JsonMetadata -Name 'software'
    $softwareName = Get-MetadataValue -Names 'name' -Source $software
}
$tagJson = Get-MetadataValue -Names 'ss_tag_frequency'

$tags = @()
if ($null -ne $tagJson) {
    try {
        $tags = @(Get-TrainingTags -Json $tagJson)
    }
    catch {
        $warnings.Add("Could not read ss_tag_frequency: $($_.Exception.Message)")
    }
}

$steps = Get-MetadataValue -Names 'ss_steps'
if ($null -eq $steps) { $steps = Get-MetadataValue -Names 'step' -Source $trainingInfo }
$epoch = Get-MetadataValue -Names 'ss_epoch'
if ($null -eq $epoch) { $epoch = Get-MetadataValue -Names 'epoch' -Source $trainingInfo }
$baseModel = Get-MetadataValue -Names 'ss_sd_model_name', 'ss_base_model'
if ($null -eq $baseModel) { $baseModel = Get-MetadataValue -Names 'base_model_name' -Source $trainingConfig }
$resolution = Get-MetadataValue -Names 'modelspec.resolution', 'ss_resolution'
if ($null -eq $resolution) { $resolution = Get-MetadataValue -Names 'resolution' -Source $trainingConfig }

$tensorEntries = @($header.PSObject.Properties | Where-Object { $_.Name -cne '__metadata__' })
foreach ($entry in $tensorEntries) {
    $tensor = $entry.Value
    if ($tensor -isnot [System.Management.Automation.PSCustomObject] -or
        $tensor.dtype -isnot [string] -or [string]::IsNullOrWhiteSpace($tensor.dtype) -or
        $tensor.shape -isnot [array]) {
        throw "Invalid tensor '$($entry.Name)': expected a data type and a shape array."
    }
    foreach ($dimension in $tensor.shape) {
        if (($dimension -isnot [int] -and $dimension -isnot [long]) -or $dimension -lt 0) {
            throw "Invalid tensor '$($entry.Name)': shape dimensions must be nonnegative integers."
        }
    }
}
$tensors = @()
if ($TensorList) {
    $tensors = @(foreach ($entry in $tensorEntries) {
        [pscustomobject]@{
            Name  = $entry.Name
            DType = $entry.Value.dtype
            Shape = @($entry.Value.shape)
        }
    })
}

$sha256 = $null
if ($Hash) {
    $sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

$result = [pscustomobject]@{
    FilePath         = $file.FullName
    SizeBytes        = $file.Length
    SHA256           = $sha256
    TensorCount      = $tensorEntries.Count
    Tensors          = $tensors
    HasMetadata      = @($metadata.PSObject.Properties).Count -gt 0
    Title            = Get-MetadataValue -Names 'modelspec.title', 'ss_output_name', 'name'
    Description      = Get-MetadataValue -Names 'modelspec.description', 'description'
    BaseModel        = $baseModel
    BaseModelVersion = Get-MetadataValue -Names 'ss_base_model_version'
    Architecture     = Get-MetadataValue -Names 'modelspec.architecture'
    Resolution       = $resolution
    TrainingSteps    = $steps
    TrainingEpoch    = $epoch
    TriggerPhrase    = Get-MetadataValue -Names 'modelspec.trigger_phrase'
    UsageHint        = Get-MetadataValue -Names 'modelspec.usage_hint'
    ModelTags        = Get-MetadataValue -Names 'modelspec.tags'
    Software         = $softwareName
    TrainingTags     = $tags
    Warnings         = $warnings.ToArray()
    Metadata         = $metadata
}

if ($Format -eq 'Json') {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $result | ConvertTo-Json -Depth 10
}
else {
    $result
}
