# Builds the Windows release and packages it as build\installer\CartunezPOS-Setup-<version>.exe
# Usage (from apps\flutter):  powershell -ExecutionPolicy Bypass -File windows\installer\build.ps1
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot\..\..").ProviderPath
Set-Location $root

$version = (Select-String -Path pubspec.yaml -Pattern '^version:\s*([0-9.]+)').Matches[0].Groups[1].Value

flutter build windows --release
if ($LASTEXITCODE -ne 0) { throw 'flutter build windows failed' }

$iscc = @("$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe", "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe") |
  Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw 'Inno Setup 6 not found. Install it with: winget install JRSoftware.InnoSetup' }

$crt = Get-ChildItem "${env:ProgramFiles(x86)}\Microsoft Visual Studio\*\*\VC\Redist\MSVC\*\x64\Microsoft.VC14*.CRT", "$env:ProgramFiles\Microsoft Visual Studio\*\*\VC\Redist\MSVC\*\x64\Microsoft.VC14*.CRT" -Directory -ErrorAction SilentlyContinue |
  Sort-Object FullName -Descending | Select-Object -First 1
$isccArgs = @("/DAppVersion=$version", "/DSourceDir=$root\build\windows\x64\runner\Release")
if ($crt) { $isccArgs += "/DCrtDir=$($crt.FullName)" } else { Write-Warning 'Visual C++ runtime not found; installer will rely on the system copy.' }

& $iscc @isccArgs "$PSScriptRoot\cartunez_pos.iss"
if ($LASTEXITCODE -ne 0) { throw 'Inno Setup failed' }
Get-Item "$root\build\installer\CartunezPOS-Setup-$version.exe"
