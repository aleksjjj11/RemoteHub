# Builds the Remote Hub Windows host/controller from config/build-lock.json.
#
# Usage: powershell -File tools/build-windows.ps1 [-AllowDirty]
#
# The checkout must be clean (tools/source_state.py) so the build is exactly
# its stated commit. -AllowDirty builds uncommitted changes for testing; the
# artifact is then labeled <commit>-dirty and is not a release.
#
# Prerequisites (checked by `python tools/doctor.py --target windows-x64`):
#   Visual Studio 2022 Build Tools (MSVC + Windows SDK) in a Developer shell,
#   LLVM 15.0.6, VCPKG_ROOT with the x64-windows-static packages,
#   RH_FLUTTER (Flutter 3.24.5), RH_TOOLS (flutter_rust_bridge_codegen 1.80.1).
# Optional: RH_BUILD_DIR staging directory (default ..\remote-hub-build-windows).
#
# The repository is not modified; sources are staged first. Any failing step
# stops the script (exit code 1); doctor failure exits 3. No signing.
# STATUS: written from the upstream CI recipe; it has NOT been run yet
# (no Windows build machine was available). Record msvc/windowsSdk in the
# build lock after the first successful run.
param([switch]$AllowDirty)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Step($name, [scriptblock]$block) {
  Write-Host "== $name"
  & $block
  if ($LASTEXITCODE -ne 0) { Write-Error "$name failed ($LASTEXITCODE)"; exit 1 }
}

$Root = (Resolve-Path "$PSScriptRoot\..").Path
$Lock = Get-Content "$Root\config\build-lock.json" -Raw | ConvertFrom-Json
$Target = $Lock.targets.'windows-x64'
$Flutter = if ($env:RH_FLUTTER) { $env:RH_FLUTTER } else { 'flutter' }
$Tools = if ($env:RH_TOOLS) { $env:RH_TOOLS } else { "$HOME\.cargo" }
$Out = if ($env:RH_BUILD_DIR) { $env:RH_BUILD_DIR } else { "$(Split-Path $Root)\remote-hub-build-windows" }
$Src = "$Out\src"

python "$Root\tools\doctor.py" --target windows-x64
if ($LASTEXITCODE -ne 0) { exit 3 }

# Staging copies the working tree, so the label must describe the working tree.
$SourceArgs = @($Root)
$VerifyArgs = @('--release')
if ($AllowDirty) { $SourceArgs += '--allow-dirty'; $VerifyArgs = @() }
$Commit = python "$Root\tools\source_state.py" @SourceArgs
if ($LASTEXITCODE -ne 0) { exit 1 }

Step 'stage sources' {
  New-Item -ItemType Directory -Force $Src | Out-Null
  Get-ChildItem $Src -Force | Where-Object Name -ne 'target' | Remove-Item -Recurse -Force
  Push-Location $Root
  $files = @(git ls-files --recurse-submodules) + @(git ls-files -o --exclude-standard)
  foreach ($f in $files) {
    $dest = Join-Path $Src $f
    New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
    Copy-Item -LiteralPath (Join-Path $Root $f) -Destination $dest -Force
  }
  Pop-Location
}
Set-Location $Src
# Remote Hub executable, version resource and window name (not rustdesk.exe).
Step 'Remote Hub identity' { python "$Root\tools\windows_identity.py" $Src }
$Exe = "$($Lock.product.appName).exe"

Step 'vcpkg x64-windows-static' {
  & "$env:VCPKG_ROOT\vcpkg" install --triplet $Target.vcpkgTriplet --x-install-root="$env:VCPKG_ROOT\installed"
}
Step 'flutter pub get' { Push-Location flutter; & $Flutter pub get; Pop-Location }
Step 'bridge codegen' {
  & "$Tools\bin\flutter_rust_bridge_codegen" --rust-input .\src\flutter_ffi.rs `
    --dart-output .\flutter\lib\generated_bridge.dart --c-output .\flutter\macos\Runner\bridge_generated.h
}
Step "cargo build ($($Target.rust))" {
  rustup run $Target.rust cargo build --locked --features $Target.cargoFeatures --lib --release
}
# The virtual display helper is a separate workspace member; the root --lib
# build does not produce it and Flutter's Windows build does not run Cargo
# (upstream build.py builds it the same way before packaging).
Step "cargo build virtual display helper ($($Target.rust))" {
  rustup run $Target.rust cargo build --locked --release -p dylib_virtual_display
}
Step 'flutter build windows' {
  Push-Location flutter
  & $Flutter build windows --release "--dart-define=$($Lock.product.dartDefine)"
  Pop-Location
}
Step 'copy virtual display driver helper' {
  Copy-Item target\release\deps\dylib_virtual_display.dll flutter\build\windows\x64\runner\Release\
}
Step 'verify artifact' {
  python "$Root\tools\verify-release.py" windows flutter\build\windows\x64\runner\Release --commit $Commit @VerifyArgs
}
New-Item -ItemType Directory -Force "$Out\artifacts" | Out-Null
Compress-Archive -Force flutter\build\windows\x64\runner\Release\* "$Out\artifacts\RemoteHub-windows-x64.zip"
Write-Host "== done: $Out\artifacts\RemoteHub-windows-x64.zip ($Exe, source $Commit)"
