param(
    [Parameter(Mandatory)]
    [string]$Destination
)

$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot '../mods/rail_crane'
$scripts = Join-Path $PSScriptRoot '../dfhack-config/scripts'
$install = New-Item -ItemType Directory -Path $Destination -Force
$targetInfo = Join-Path $install.FullName 'info.txt'
$uploadId = if (Test-Path -LiteralPath $targetInfo) {
    Select-String -LiteralPath $targetInfo -Pattern '^\[STEAM_FILE_ID:\d+\]\s*$' |
        Select-Object -First 1 -ExpandProperty Line
}

foreach ($entry in @('info.txt', 'preview.png', 'graphics', 'objects')) {
    Copy-Item -LiteralPath (Join-Path $source $entry) -Destination $install.FullName -Recurse -Force
}
if ($uploadId -and -not (Select-String -LiteralPath $targetInfo -Pattern '^\[STEAM_FILE_ID:')) {
    Add-Content -LiteralPath $targetInfo -Value $uploadId.Trim()
}

$activeScripts = New-Item -ItemType Directory -Path (Join-Path $install.FullName 'scripts_modactive') -Force
Copy-Item -LiteralPath (Join-Path $scripts 'rail-crane.lua') -Destination $activeScripts.FullName -Force
$internal = New-Item -ItemType Directory -Path (Join-Path $activeScripts.FullName 'internal') -Force
Copy-Item -LiteralPath (Join-Path $scripts 'internal/rail-crane') -Destination $internal.FullName -Recurse -Force
Write-Output $install.FullName
