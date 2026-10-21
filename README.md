# Directory Opus Metadata Inspectors

Scripts for viewing AI model and media metadata in [Directory Opus](https://www.gpsoft.com.au/).

Planned features:

- Show base model, training steps, descriptions, and training tags from `.safetensors` files.
- Read embedded ComfyUI workflows, including models and prompts.
- View metadata through Directory Opus columns and inspector windows.

Development has just started. Directory Opus integration is not available yet.

## Usage

```powershell
$result = .\src\Get-SafeTensorMetadata.ps1 -Path 'C:\Models\example.safetensors'
$result.Metadata | Format-List
```

## Metadata

Metadata availability depends on the file format and the software used to create it. Some models contain little or no embedded metadata.

Training tags and their frequencies do not necessarily correspond to a model's trigger words.
