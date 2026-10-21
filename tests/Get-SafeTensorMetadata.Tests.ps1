#Requires -Version 5.1

$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '..\src\Get-SafeTensorMetadata.ps1'
$testDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('opus-tests-' + [guid]::NewGuid())
[void][System.IO.Directory]::CreateDirectory($testDirectory)
$utf8 = [System.Text.Encoding]::UTF8

function New-TestFile {
    param(
        [byte[]]$Header,
        [Nullable[uint64]]$HeaderLength = $null,
        [byte[]]$Payload = @(),
        [string]$Name = 'model.safetensors'
    )

    if ($null -eq $HeaderLength) { $HeaderLength = $Header.Length }
    $path = Join-Path $testDirectory $Name
    $writer = [System.IO.BinaryWriter]::new([System.IO.File]::Create($path))
    try {
        $writer.Write([uint64]$HeaderLength)
        $writer.Write($Header)
        $writer.Write($Payload)
    }
    finally {
        $writer.Dispose()
    }
    return $path
}

function Read-TestMetadata {
    param([hashtable]$Metadata)

    $json = @{ __metadata__ = $Metadata } | ConvertTo-Json -Depth 10 -Compress
    $path = New-TestFile -Header $utf8.GetBytes($json)
    & $scriptPath -Path $path
}

function Assert-Equal {
    param($Actual, $Expected)
    if ($Actual -cne $Expected) {
        throw "Expected '$Expected', got '$Actual'."
    }
}

function Assert-Rejected {
    param([string]$Path, [string]$Message)
    try {
        & $scriptPath -Path $Path | Out-Null
    }
    catch {
        if ($_.Exception.Message -notlike "*$Message*") { throw }
        return
    }
    throw "Expected the reader to reject '$Path'."
}

try {
    # File reading
    $json = '{"__metadata__":{"ss_steps":"1200"},"weight":{"dtype":"F32","shape":[1],"data_offsets":[0,4]}}'
    $path = New-TestFile -Header $utf8.GetBytes($json) -Payload ([byte[]]@(0, 0, 0, 0))
    $result = & $scriptPath -Path $path
    Assert-Equal $result.FilePath $path
    Assert-Equal $result.Metadata.ss_steps '1200'
    Assert-Equal ($result.Metadata.ss_steps -is [string]) $true

    # File size, tensor details, and optional hashing
    Assert-Equal $result.SizeBytes (8 + $utf8.GetByteCount($json) + 4)
    Assert-Equal $result.TensorCount 1
    Assert-Equal $result.Tensors.Count 0
    Assert-Equal $result.SHA256 $null
    $result = & $scriptPath -Path $path -TensorList
    Assert-Equal $result.Tensors.Count 1
    Assert-Equal $result.Tensors[0].Name 'weight'
    Assert-Equal $result.Tensors[0].DType 'F32'
    Assert-Equal ($result.Tensors[0].Shape -is [array]) $true
    Assert-Equal $result.Tensors[0].Shape.Count 1
    Assert-Equal $result.Tensors[0].Shape[0] 1

    # Independent digest of the exact fixture bytes.
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    try {
        $digest = $hasher.ComputeHash([System.IO.File]::ReadAllBytes($path))
        $expectedHash = ([System.BitConverter]::ToString($digest)).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $hasher.Dispose()
    }
    $result = & $scriptPath -Path $path -Hash
    Assert-Equal $result.SHA256 $expectedHash

    $jsonResult = & $scriptPath -Path $path -TensorList -Hash -Format Json
    Assert-Equal ($jsonResult -is [string]) $true
    $decoded = $jsonResult | ConvertFrom-Json
    Assert-Equal $decoded.FilePath $path
    Assert-Equal $decoded.SizeBytes $result.SizeBytes
    Assert-Equal $decoded.SHA256 $expectedHash
    Assert-Equal $decoded.Metadata.ss_steps '1200'
    Assert-Equal ($decoded.Tensors -is [array]) $true
    Assert-Equal $decoded.Tensors.Count 1
    Assert-Equal $decoded.Tensors[0].Name 'weight'
    Assert-Equal ($decoded.Tensors[0].Shape -is [array]) $true
    Assert-Equal $decoded.Tensors[0].Shape[0] 1
    Assert-Equal ($decoded.TrainingTags -is [array]) $true
    Assert-Equal ($decoded.Warnings -is [array]) $true

    $json = '{"scalar":{"dtype":"F32","shape":[],"data_offsets":[0,4]},"matrix":{"dtype":"F16","shape":[2,3],"data_offsets":[4,16]}}'
    $path = New-TestFile -Header $utf8.GetBytes($json) -Payload ([byte[]]::new(16))
    $result = & $scriptPath -Path $path -TensorList
    Assert-Equal $result.TensorCount 2
    $scalar = $result.Tensors | Where-Object { $_.Name -eq 'scalar' }
    $matrix = $result.Tensors | Where-Object { $_.Name -eq 'matrix' }
    Assert-Equal $scalar.Shape.Count 0
    Assert-Equal $matrix.DType 'F16'
    Assert-Equal ($matrix.Shape -join ',') '2,3'

    foreach ($header in @('{}', '{"__metadata__":{}}      ')) {
        $path = New-TestFile -Header $utf8.GetBytes($header)
        $result = & $scriptPath -Path $path
        Assert-Equal $result.HasMetadata $false
        Assert-Equal @($result.Metadata.PSObject.Properties).Count 0
        Assert-Equal $result.TrainingSteps $null
        Assert-Equal $result.TrainingTags.Count 0
        Assert-Equal $result.Warnings.Count 0
        Assert-Equal $result.TensorCount 0
        $decoded = & $scriptPath -Path $path -TensorList -Format Json | ConvertFrom-Json
        Assert-Equal ($decoded.Tensors -is [array]) $true
        Assert-Equal $decoded.Tensors.Count 0
        Assert-Equal $decoded.SHA256 $null
    }

    # Dates should stay as strings.
    foreach ($date in @('2026-05-25T00:08:41', '2026-05-25T00:08:41Z', '2026-05-25T00:08:41.123+02:00')) {
        $result = Read-TestMetadata @{ 'modelspec.date' = $date }
        Assert-Equal ($result.Metadata.'modelspec.date' -is [string]) $true
        Assert-Equal $result.Metadata.'modelspec.date' $date
    }

    $text = 'caf' + [char]0xE9
    $path = New-TestFile -Header $utf8.GetBytes('{"__metadata__":{"description":"' + $text + '"}}') -Name "model [$text].safetensors"
    $result = & $scriptPath -Path $path
    Assert-Equal $result.Metadata.description $text
    $decoded = & $scriptPath -Path $path -Format Json | ConvertFrom-Json
    Assert-Equal $decoded.FilePath $path
    Assert-Equal $decoded.Metadata.description $text

    # Incomplete or invalid headers
    $path = Join-Path $testDirectory 'short.safetensors'
    [System.IO.File]::WriteAllBytes($path, [byte[]]@(0, 0, 0))
    Assert-Rejected $path 'too short'

    $path = New-TestFile -Header $utf8.GetBytes('{}') -HeaderLength 20
    Assert-Rejected $path 'before the declared'

    foreach ($length in @([uint64]0, [uint64]1, [uint64]100000001, [uint64]::MaxValue)) {
        $path = New-TestFile -Header ([byte[]]@()) -HeaderLength $length
        Assert-Rejected $path 'Invalid SafeTensors header length'
    }
    $path = New-TestFile -Header $utf8.GetBytes('[]')
    Assert-Rejected $path 'must begin with a JSON object'
    $path = New-TestFile -Header $utf8.GetBytes('{broken}')
    Assert-Rejected $path 'invalid JSON'
    $path = New-TestFile -Header ([byte[]]@(0x7B, 0x22, 0xFF, 0x22, 0x3A, 0x22, 0x22, 0x7D))
    Assert-Rejected $path 'invalid UTF-8'
    foreach ($value in @('null', '[]', '"text"')) {
        $path = New-TestFile -Header $utf8.GetBytes('{"__metadata__":' + $value + '}')
        Assert-Rejected $path 'metadata must be a JSON object'
    }
    foreach ($value in @('42', 'null', '{}', '[]', 'true')) {
        $path = New-TestFile -Header $utf8.GetBytes('{"__metadata__":{"steps":' + $value + '}}')
        Assert-Rejected $path "metadata value 'steps' must be a string"
    }
    Assert-Rejected (Join-Path $testDirectory 'missing.safetensors') 'does not exist'

    foreach ($header in @('{}', '{broken}')) {
        $path = New-TestFile -Header $utf8.GetBytes($header)
        if ($header -eq '{}') { & $scriptPath -Path $path | Out-Null }
        else { Assert-Rejected $path 'invalid JSON' }
        $file = [System.IO.File]::Open($path, 'Open', 'ReadWrite', 'None')
        $file.Dispose()
    }

    # ModelSpec and Kohya fields
    $result = Read-TestMetadata @{
        'modelspec.title' = 'Example LoRA'
        'modelspec.description' = 'An example model'
        'modelspec.architecture' = 'example/lora'
        'modelspec.resolution' = '1280x720'
        ss_output_name = 'training-name'
        ss_resolution = '(1024, 1024)'
        ss_sd_model_name = 'base.safetensors'
        ss_base_model_version = 'example_9b'
        ss_steps = '1920'
        ss_epoch = '4'
    }
    Assert-Equal $result.HasMetadata $true
    Assert-Equal $result.Title 'Example LoRA'
    Assert-Equal $result.Description 'An example model'
    Assert-Equal $result.Architecture 'example/lora'
    Assert-Equal $result.Resolution '1280x720'
    Assert-Equal $result.BaseModel 'base.safetensors'
    Assert-Equal $result.BaseModelVersion 'example_9b'
    Assert-Equal $result.TrainingSteps '1920'
    Assert-Equal $result.TrainingEpoch '4'

    $result = Read-TestMetadata @{ 'modelspec.title' = ' '; ss_output_name = 'training-name'; ss_resolution = '(1024, 1024)' }
    Assert-Equal $result.Title 'training-name'
    Assert-Equal $result.Resolution '(1024, 1024)'

    $result = Read-TestMetadata @{ ss_max_train_steps = '2000'; ss_num_epochs = '10' }
    Assert-Equal $result.TrainingSteps $null
    Assert-Equal $result.TrainingEpoch $null

    $result = Read-TestMetadata @{ ss_steps = '0'; ss_epoch = '0' }
    Assert-Equal $result.TrainingSteps '0'
    Assert-Equal $result.TrainingEpoch '0'

    # Tag counts and sorting
    $tagJson = '{"a":{"portrait":3,"zebra":2,"apple":2},"b":{"portrait":2},"c":{"Portrait":1}}'
    $result = Read-TestMetadata @{ ss_tag_frequency = $tagJson }
    Assert-Equal $result.Metadata.ss_tag_frequency $tagJson
    Assert-Equal $result.TrainingTags.Count 4
    Assert-Equal $result.TrainingTags[0].Tag 'portrait'
    Assert-Equal $result.TrainingTags[0].Count 5
    Assert-Equal $result.TrainingTags[1].Tag 'apple'
    Assert-Equal $result.TrainingTags[2].Tag 'zebra'
    Assert-Equal $result.TrainingTags[3].Tag 'Portrait'
    Assert-Equal $result.TriggerPhrase $null
    Assert-Equal $result.Warnings.Count 0
    foreach ($tagJson in @('{}', '{"set":{}}')) {
        $result = Read-TestMetadata @{ ss_tag_frequency = $tagJson }
        Assert-Equal ($result.TrainingTags -is [array]) $true
        Assert-Equal $result.TrainingTags.Count 0
    }
    $result = Read-TestMetadata @{ ss_tag_frequency = '{"set":{"portrait":0}}' }
    Assert-Equal ($result.TrainingTags -is [array]) $true
    Assert-Equal $result.TrainingTags.Count 1
    Assert-Equal $result.TrainingTags[0].Count 0
    $invalidTags = @('{broken}', 'null', '[]', '{"set":null}', '{"set":{"portrait":-1}}', '{"set":{"portrait":1.5}}', '{"a":{"portrait":9223372036854775807},"b":{"portrait":1}}')
    foreach ($tagJson in $invalidTags) {
        $result = Read-TestMetadata @{ ss_output_name = 'Example'; ss_tag_frequency = $tagJson }
        Assert-Equal $result.Title 'Example'
        Assert-Equal $result.TrainingTags.Count 0
        Assert-Equal $result.Warnings.Count 1
    }

    # AI Toolkit
    foreach ($step in @(0, 1200)) {
        $trainingInfo = @{ step = $step; epoch = 3 } | ConvertTo-Json -Compress
        $result = Read-TestMetadata @{
            ss_output_name = 'Toolkit LoRA'
            training_info = $trainingInfo
            software = '{"name":"ai-toolkit","version":"example"}'
        }
        Assert-Equal $result.Title 'Toolkit LoRA'
        Assert-Equal $result.TrainingSteps $step
        Assert-Equal $result.TrainingEpoch 3
        Assert-Equal $result.Software 'ai-toolkit'
        Assert-Equal $result.Metadata.training_info $trainingInfo
    }
    foreach ($value in @('{broken}', '[]', '[{}]', 'null')) {
        $result = Read-TestMetadata @{ ss_steps = '50'; training_info = $value }
        Assert-Equal $result.TrainingSteps '50'
        Assert-Equal $result.Metadata.training_info $value
        Assert-Equal $result.Warnings.Count 1
    }

    # OneTrainer: configured epochs are not completed epochs.
    $config = '{"base_model_name":"example/base","resolution":"1024","epochs":20}'
    $result = Read-TestMetadata @{ 'modelspec.title' = 'OneTrainer LoRA'; ot_config = $config }
    Assert-Equal $result.Title 'OneTrainer LoRA'
    Assert-Equal $result.BaseModel 'example/base'
    Assert-Equal $result.Resolution '1024'
    Assert-Equal $result.TrainingEpoch $null
    $result = Read-TestMetadata @{ ss_steps = '50'; ss_epoch = '1'; training_info = '{"step":100,"epoch":2}' }
    Assert-Equal $result.TrainingSteps '50'
    Assert-Equal $result.TrainingEpoch '1'

    # Fizgig trigger phrase and tags
    $result = Read-TestMetadata @{
        'modelspec.trigger_phrase' = 'example subject'
        'modelspec.usage_hint' = "Include 'example subject' in your prompt."
        'modelspec.tags' = 'portrait, style'
    }
    Assert-Equal $result.TriggerPhrase 'example subject'
    Assert-Equal $result.UsageHint "Include 'example subject' in your prompt."
    Assert-Equal $result.ModelTags 'portrait, style'
    Assert-Equal $result.TrainingTags.Count 0

    # Raw metadata should stay unchanged.
    $metadata = @{
        name = 'Custom LoRA'
        description = "Training notes about this model.`n" * 150
        custom_settings = '{"anything":[1,2,3]}'
        software = 'custom trainer'
        '_' = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_,. -' * 80
        'modelspec.thumbnail' = 'data:image/png;base64,iVBORw0KGgo='
    }
    $result = Read-TestMetadata $metadata
    Assert-Equal $result.Title 'Custom LoRA'
    Assert-Equal $result.Software 'custom trainer'
    foreach ($name in $metadata.Keys) {
        Assert-Equal $result.Metadata.PSObject.Properties[$name].Value $metadata[$name]
    }
}
finally {
    [System.IO.Directory]::Delete($testDirectory, $true)
}

Write-Host 'SafeTensors metadata checks passed.'
