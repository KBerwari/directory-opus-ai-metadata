#Requires -Version 5.1

param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Path
)

$file = Get-Item -LiteralPath $Path -ErrorAction Stop
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
        $header = ConvertFrom-Json -InputObject $headerText -ErrorAction Stop
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

[pscustomobject]@{
    FilePath = $file.FullName
    Metadata = $metadata
}
