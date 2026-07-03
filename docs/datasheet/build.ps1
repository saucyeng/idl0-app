# Build the IDL0 datasheet PDF.
#
# Requires Typst on PATH. Install: `winget install Typst.Typst` or grab the
# binary from https://github.com/typst/typst/releases and drop it on PATH.

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

if (-not (Get-Command typst -ErrorAction SilentlyContinue)) {
    Write-Error "Typst not found on PATH. Install via 'winget install Typst.Typst' or download from https://github.com/typst/typst/releases"
}

# --watch for live rebuild during editing; comment out for one-shot CI build.
if ($args -contains '--watch') {
    typst watch main.typ idl0-datasheet.pdf
} else {
    typst compile main.typ idl0-datasheet.pdf
    Write-Output "Built: $PSScriptRoot\idl0-datasheet.pdf"
}
