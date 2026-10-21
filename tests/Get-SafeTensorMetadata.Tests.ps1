#Requires -Version 5.1

$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '..\src\Get-SafeTensorMetadata.ps1'
$testDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('opus-metadata-tests-' + [guid]::NewGuid())
[void][System.IO.Directory]::CreateDirectory($testDirectory)

function New-TestFile {
    param(
        [byte[]]$Header,
        [Nullable[uint64]]$HeaderLength = $null,
        [byte[]]$Payload = @(),
        [string]$Name = 'model.safetensors'
    )

    if ($null -eq $HeaderLength) { $HeaderLength = $Header.Length }
    $path = Join-Path $testDirectory $Name
    $stream = [System.IO.File]::Create($path)
    $writer = [System.IO.BinaryWriter]::new($stream)
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

$utf8 = [System.Text.Encoding]::UTF8
$tests = [ordered]@{
    'Reads metadata and preserves JSON strings' = {
        $json = '{"__metadata__":{"ss_steps":"1200","ss_tag_frequency":"{\"portrait\":4}"},"weight":{"dtype":"F32","shape":[1],"data_offsets":[0,4]}}'
        $path = New-TestFile -Header $utf8.GetBytes($json) -Payload ([byte[]]@(0, 0, 0, 0))
        $result = & $scriptPath -Path $path
        Assert-Equal $result.FilePath $path
        Assert-Equal $result.Metadata.ss_steps '1200'
        Assert-Equal $result.Metadata.ss_tag_frequency '{"portrait":4}'
        Assert-Equal ($result.Metadata.ss_steps -is [string]) $true
    }
    'Returns empty metadata when it is absent' = {
        $path = New-TestFile -Header $utf8.GetBytes('{}')
        $result = & $scriptPath -Path $path
        Assert-Equal @($result.Metadata.PSObject.Properties).Count 0
    }
    'Accepts padding and empty metadata' = {
        $path = New-TestFile -Header $utf8.GetBytes('{"__metadata__":{}}      ')
        $result = & $scriptPath -Path $path
        Assert-Equal @($result.Metadata.PSObject.Properties).Count 0
    }
    'Preserves Unicode and treats brackets in paths literally' = {
        $text = 'caf' + [char]0xE9
        $json = '{"__metadata__":{"description":"' + $text + '"}}'
        $path = New-TestFile -Header $utf8.GetBytes($json) -Name ('model [' + $text + '].safetensors')
        $result = & $scriptPath -Path $path
        Assert-Equal $result.Metadata.description $text
    }
    'Rejects files shorter than eight bytes' = {
        $path = Join-Path $testDirectory 'short.safetensors'
        [System.IO.File]::WriteAllBytes($path, [byte[]]@(0, 0, 0))
        Assert-Rejected $path 'too short'
    }
    'Rejects a truncated header' = {
        $path = New-TestFile -Header $utf8.GetBytes('{}') -HeaderLength 20
        Assert-Rejected $path 'before the declared'
    }
    'Rejects invalid header lengths before allocating memory' = {
        foreach ($length in @([uint64]0, [uint64]1, [uint64]100000001, [uint64]::MaxValue)) {
            $path = New-TestFile -Header ([byte[]]@()) -HeaderLength $length
            Assert-Rejected $path 'Invalid SafeTensors header length'
        }
    }
    'Rejects headers that do not start with an object' = {
        $path = New-TestFile -Header $utf8.GetBytes('[]')
        Assert-Rejected $path 'must begin with a JSON object'
    }
    'Rejects malformed JSON' = {
        $path = New-TestFile -Header $utf8.GetBytes('{broken}')
        Assert-Rejected $path 'invalid JSON'
    }
    'Rejects invalid UTF-8' = {
        $path = New-TestFile -Header ([byte[]]@(0x7B, 0x22, 0xFF, 0x22, 0x3A, 0x22, 0x22, 0x7D))
        Assert-Rejected $path 'invalid UTF-8'
    }
    'Rejects metadata that is not an object' = {
        foreach ($value in @('null', '[]', '"text"')) {
            $path = New-TestFile -Header $utf8.GetBytes('{"__metadata__":' + $value + '}')
            Assert-Rejected $path 'metadata must be a JSON object'
        }
    }
    'Rejects non-string metadata values' = {
        foreach ($value in @('42', 'null', '{}', '[]', 'true')) {
            $path = New-TestFile -Header $utf8.GetBytes('{"__metadata__":{"steps":' + $value + '}}')
            Assert-Rejected $path "metadata value 'steps' must be a string"
        }
    }
    'Reports a missing file' = {
        Assert-Rejected (Join-Path $testDirectory 'missing.safetensors') 'does not exist'
    }
    'Closes the file after success and failure' = {
        foreach ($json in @('{}', '{broken}')) {
            $path = New-TestFile -Header $utf8.GetBytes($json)
            try { & $scriptPath -Path $path | Out-Null } catch { }
            $stream = [System.IO.File]::Open($path, 'Open', 'ReadWrite', 'None')
            $stream.Dispose()
        }
    }
}

$failed = 0
try {
    foreach ($test in $tests.GetEnumerator()) {
        try {
            & $test.Value
            Write-Host "PASS $($test.Key)"
        }
        catch {
            $failed++
            Write-Host "FAIL $($test.Key): $($_.Exception.Message)"
        }
    }
}
finally {
    # Delete only the unique temporary directory created by this run.
    [System.IO.Directory]::Delete($testDirectory, $true)
}

if ($failed -gt 0) { throw "$failed test(s) failed." }
Write-Host "$($tests.Count) tests passed."
