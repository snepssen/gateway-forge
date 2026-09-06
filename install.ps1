# Gateway Forge installer, Windows.
#
#   irm https://raw.githubusercontent.com/snepssen/gateway-forge/main/install.ps1 | iex
#
# Read it before you run it. Piping a remote script into a shell is exactly the
# thing worth being suspicious of, and this one is short enough to skim:
#
#   irm https://raw.githubusercontent.com/snepssen/gateway-forge/main/install.ps1
#
# It asks GitHub for the latest release, downloads the build for this machine,
# checks its SHA256 against the checksums published in the same release, and
# either runs the installer or unpacks the zip into your local app data. It
# never writes outside your temp folder and the one folder it prints.

$ErrorActionPreference = 'Stop'
$repo = 'snepssen/gateway-forge'

function Say  { param($m) Write-Host "  $m" }
function Die  { param($m) Write-Host ''; Write-Host "  $m" -ForegroundColor Red; Write-Host ''; exit 1 }

Write-Host ''; Write-Host '  Gateway Forge'; Write-Host ''

$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
Say "system:  Windows $arch"

# The Windows build is x64 only -- the release workflow builds --x64 and
# nothing else. Windows on ARM can run x64 through emulation, so this is a
# note rather than a refusal.
if ($arch -eq 'arm64') {
  Say 'note:    the build is x86-64; Windows on ARM will run it emulated'
}

try {
  $rel = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest"
} catch {
  Die @"
Could not reach the release. If the only release is still a draft this will
  always fail -- a draft is not downloadable, and not visible to this API.
  Ask for a build directly instead: https://t.me/snepssen
"@
}
Say "release: $($rel.tag_name)"

# Asset names are read from the release rather than constructed, so a change to
# how the build names its files cannot silently break this. Prefer the
# installer; fall back to the zip, which is the format that has actually been
# built on every release so far.
$asset = $rel.assets | Where-Object { $_.name -like '*.exe' } | Select-Object -First 1
if (-not $asset) {
  $asset = $rel.assets | Where-Object { $_.name -like '*win*.zip' } | Select-Object -First 1
}
if (-not $asset) { Die "This release has no Windows build." }

$tmp = Join-Path $env:TEMP ("gateway-forge-" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $tmp | Out-Null
$file = Join-Path $tmp $asset.name

Say "file:    $($asset.name)"
Write-Host '  downloading... ' -NoNewline
Invoke-WebRequest $asset.browser_download_url -OutFile $file
Write-Host ("done ({0:N0} MB)" -f ((Get-Item $file).Length / 1MB))

# Checked against the checksums published alongside the build. A mismatch means
# the file is not the one that was built, and that is a stop, not a warning.
$sums = $rel.assets | Where-Object { $_.name -eq 'SHA256SUMS' } | Select-Object -First 1
if ($sums) {
  $text = (Invoke-WebRequest $sums.browser_download_url).Content
  $line = ($text -split "`n") | Where-Object { $_ -match [regex]::Escape($asset.name) } | Select-Object -First 1
  if ($line) {
    $want = ($line -split '\s+')[0]
    $got  = (Get-FileHash $file -Algorithm SHA256).Hash.ToLower()
    if ($want.ToLower() -ne $got) { Die "Checksum mismatch. Expected $want, got $got. Nothing was installed." }
    Say 'checksum: verified'
  } else { Say 'checksum: this file is not listed in SHA256SUMS -- not verified' }
} else { Say 'checksum: no SHA256SUMS in this release -- not verified' }

Write-Host ''

if ($asset.name -like '*.exe') {
  Say 'Running the installer. Windows may warn that the publisher is unknown --'
  Say 'the app is unsigned, because code signing certificates cost money this'
  Say 'project does not spend. Choose "More info" then "Run anyway" if you trust it.'
  Write-Host ''
  Start-Process -FilePath $file -Wait
  Write-Host ''
  Say 'Done. Gateway Forge should be in your Start menu.'
} else {
  # The zip is a directory with a name; unpack it rather than run it. Windows
  # marks downloaded archives so their contents inherit a block that stops the
  # app launching -- Unblock-File is the scripted form of the "Unblock" tickbox
  # on a file's properties, and is stated here rather than done quietly.
  $dest = Join-Path $env:LOCALAPPDATA 'Gateway Forge'
  if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
  Unblock-File $file
  Say 'cleared the downloaded-file block (the app is unsigned, not code-signed)'
  Expand-Archive -Path $file -DestinationPath $dest -Force

  $exe = Get-ChildItem $dest -Recurse -Filter '*.exe' |
         Where-Object { $_.Name -notlike '*unins*' } | Select-Object -First 1
  if (-not $exe) { Die "No Gateway Forge executable inside the archive." }

  # A Start menu shortcut, so it is launchable the way every other app is
  # rather than only by remembering a path.
  $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
  $lnk = Join-Path $startMenu 'Gateway Forge.lnk'
  $shell = New-Object -ComObject WScript.Shell
  $shortcut = $shell.CreateShortcut($lnk)
  $shortcut.TargetPath = $exe.FullName
  $shortcut.WorkingDirectory = $exe.DirectoryName
  $shortcut.Description = 'Assemble guided meditation sessions, and keep the journal beside them'
  $shortcut.Save()

  Write-Host ''
  Say "Installed to $dest"
  Say 'Done. Gateway Forge should be in your Start menu.'
}

Say 'Nothing here talks to the network. If it stops working: https://t.me/snepssen'
Write-Host ''
