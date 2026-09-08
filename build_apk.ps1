# Build the dsh_mobile_app Android APK using local toolchain only.
#
# Uses the locally installed Gradle (gradle-9.5.1) and Android Studio's JDK —
# no network downloads. Requires the machine-local paths below to exist.
#
# Usage: powershell -ExecutionPolicy Bypass -File build_apk.ps1
# Output: <repo>\dsh_mobile_app-v<version>.apk

$ErrorActionPreference = 'Stop'

# --- local toolchain (machine-specific) ---
$Gradle = 'C:\Users\Administrator\gradle-local\gradle-9.5.1\bin\gradle.bat'
$JavaHome = 'C:\Program Files\Android\Android Studio\jbr'

$AppDir = Join-Path $PSScriptRoot 'dsh_mobile_app'
$AndroidDir = Join-Path $AppDir 'android'

# --- validate local prerequisites ---
if (-not (Test-Path $Gradle)) { throw "Gradle not found at $Gradle" }
if (-not (Test-Path (Join-Path $JavaHome 'bin\javac.exe'))) { throw "JDK not found at $JavaHome" }
if (-not (Test-Path $AndroidDir)) { throw "Android project not found at $AndroidDir" }

# --- version from pubspec.yaml (e.g. "version: 1.0.2+2" -> versionName 1.0.2, versionCode 2) ---
$Pubspec = Get-Content (Join-Path $AppDir 'pubspec.yaml')
$VersionLine = $Pubspec | Where-Object { $_ -match '^version:\s*(\S+)' } | Select-Object -First 1
if (-not $VersionLine) { throw 'version not found in pubspec.yaml' }
$VersionName = ($VersionLine -replace '^version:\s*([^+]+).*', '$1').Trim()
$VersionCode = if ($VersionLine -match '\+(\d+)') { $Matches[1] } else { '1' }
Write-Host "[build_apk] building dsh_mobile_app version $VersionName (code $VersionCode)"

# --- sync the version into android/local.properties ---
# Direct gradle invocation reads flutter.versionName/Code from local.properties,
# which `flutter pub get` does NOT refresh. Rewrite it here. Must be written
# WITHOUT a BOM: java.util.Properties (ISO-8859-1) misreads a UTF-8 BOM on the
# first key and drops sdk.dir, failing the build with "SDK location not found".
$LocalProps = Join-Path $AndroidDir 'local.properties'
$PropsLines = @(
  'sdk.dir=C:\\Users\\Administrator\\AppData\\Local\\Android\\Sdk'
  'flutter.sdk=C:\\flutter'
  'flutter.buildMode=release'
  "flutter.versionName=$VersionName"
  "flutter.versionCode=$VersionCode"
)
[System.IO.File]::WriteAllLines($LocalProps, $PropsLines, (New-Object System.Text.UTF8Encoding($false)))

# --- build with local gradle + Android Studio JDK ---
$env:JAVA_HOME = $JavaHome
& $Gradle assembleRelease --no-daemon -p $AndroidDir
if ($LASTEXITCODE -ne 0) { throw "Gradle build failed (exit $LASTEXITCODE)" }

# --- copy the APK out with the version in the name ---
$Apk = Join-Path $AndroidDir '..\build\app\outputs\flutter-apk\app-release.apk'
if (-not (Test-Path $Apk)) { throw "APK not produced at $Apk" }
$Dest = Join-Path $PSScriptRoot "dsh_mobile_app-v$VersionName.apk"
Copy-Item $Apk $Dest -Force
Write-Host "[build_apk] APK -> $Dest ($((Get-Item $Dest).Length) bytes)"
