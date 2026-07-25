@echo off
SETLOCAL ENABLEDELAYEDEXPANSION
cd /d "%~dp0"
REM Claude Code Authentication Installer for Windows
REM Organization: login.microsoftonline.com/684fdbeb-a2a8-4079-a6e8-1fefe44f7477/v2.0
REM Generated: 2026-07-24 12:57:47

echo ======================================
echo Claude Code Authentication Installer
echo ======================================
echo.
echo Organization: login.microsoftonline.com/684fdbeb-a2a8-4079-a6e8-1fefe44f7477/v2.0
echo.

REM Check prerequisites
echo Checking prerequisites...

set HAS_AWS_CLI=0
where aws >nul 2>&1
if %errorlevel% neq 0 (
    echo INFO: AWS CLI not found -- not required. Profiles will be configured directly.
) else (
    set HAS_AWS_CLI=1
    echo OK AWS CLI found
)

echo OK Prerequisites found
echo.

REM Create directory
echo Installing authentication tools...
if not exist "%USERPROFILE%\claude-code-with-bedrock" mkdir "%USERPROFILE%\claude-code-with-bedrock"

REM Copy credential process executable with renamed target
echo Copying credential process...
copy /Y "credential-process-windows.exe" "%USERPROFILE%\claude-code-with-bedrock\credential-process.exe" >nul
if %errorlevel% neq 0 (
    echo ERROR: Failed to copy credential-process-windows.exe
    pause
    exit /b 1
)

REM Copy OTEL helper if it exists with renamed target
if exist "otel-helper-windows.exe" (
    echo Copying OTEL helper...
    copy /Y "otel-helper-windows.exe" "%USERPROFILE%\claude-code-with-bedrock\otel-helper.exe" >nul
)

REM Copy the OTEL helper wrapper (.cmd) and its PowerShell fallback (.ps1).
REM Claude Code's otelHeadersHelper points at otel-helper.cmd, which runs the
REM fast .exe and falls back to the .ps1 if antivirus blocks the binary. When
REM monitoring is enabled these files are REQUIRED — a missing .cmd makes Claude
REM Code fail every telemetry export with "is not recognized as an internal or
REM external command" and silently drops all metrics, so we fail the install
REM loudly rather than leave a broken telemetry config.
if exist "otel-helper.cmd" (
    copy /Y "otel-helper.cmd" "%USERPROFILE%\claude-code-with-bedrock\otel-helper.cmd" >nul
    if !errorlevel! neq 0 (
        echo ERROR: Failed to copy otel-helper.cmd
        pause
        exit /b 1
    )
) else (
    echo INFO: otel-helper.cmd not found in package.
    REM Monitoring disabled - helper not required.
)
if exist "otel-helper.ps1" (
    copy /Y "otel-helper.ps1" "%USERPROFILE%\claude-code-with-bedrock\otel-helper.ps1" >nul
    if !errorlevel! neq 0 (
        echo ERROR: Failed to copy otel-helper.ps1
        pause
        exit /b 1
    )
) else (
    echo INFO: otel-helper.ps1 not found in package.
    REM Monitoring disabled - fallback not required.
)

REM Install OTEL Collector sidecar (sidecar-mode packages only). otelcol is built
REM via OCB and SHIPPED in the package as otelcol-windows.exe (same model as the
REM other binaries) — never downloaded at install time. otel-helper.ps1 launches it
REM from %USERPROFILE%\claude-code-with-bedrock\otelcol.exe under the
REM <profile>-collector AWS profile created below.
if exist "collector-config.yaml" (
    if exist "otelcol-windows.exe" (
        echo Installing OTEL Collector sidecar...
        copy /Y "otelcol-windows.exe" "%USERPROFILE%\claude-code-with-bedrock\otelcol.exe" >nul
        copy /Y "collector-config.yaml" "%USERPROFILE%\claude-code-with-bedrock\collector-config.yaml" >nul
        REM Unblock the downloaded binary so SmartScreen doesn't block subprocess launch
        powershell -NoProfile -Command "Get-ChildItem '%USERPROFILE%\claude-code-with-bedrock\otelcol.exe' | Unblock-File" >nul 2>&1
        echo OK OTEL Collector sidecar installed
    ) else (
        echo WARNING: Sidecar config present but otelcol-windows.exe is missing.
        echo          The admin must run 'ccwb package' with Go 1.23+ to build the collector.
        echo          Telemetry will not be forwarded until the collector is installed.
    )
)

REM Copy configuration
echo Copying configuration...
copy /Y "config.json" "%USERPROFILE%\claude-code-with-bedrock\" >nul

REM Resolve __CCWB_HOME__ to the absolute home in the CoWork MDM .reg. Claude
REM Desktop does NOT expand %USERPROFILE% (or other env vars) in registry MDM
REM string values, and cowork-3p.reg is generated centrally, so the headersHelper
REM / inferenceCredentialHelper absolute paths must be baked in here before the
REM admin/user imports it. The .reg escapes backslashes, so the home is escaped
REM (\ -> \\) to match the .reg format; reg import un-escapes it back to a
REM single backslash in the stored REG_SZ value.
if exist "cowork-3p.reg" (
    echo Resolving home directory in cowork-3p.reg...
    powershell -NoProfile -Command "$h = $env:USERPROFILE.Replace('\','\\'); (Get-Content 'cowork-3p.reg' -Raw).Replace('__CCWB_HOME__', $h) | Set-Content 'cowork-3p.reg'"
    echo OK Resolved home directory in cowork-3p.reg ^(import it with: reg import cowork-3p.reg, then fully restart Claude^)
)

REM Install the CoWork credential-helper wrapper (helper-script mode). Claude
REM Desktop runs inferenceCredentialHelper with no arguments, so the --desktop
REM --profile flags live inside this wrapper, which calls the co-located binary.
if exist "cowork-credential-helper.cmd" (
    copy /Y "cowork-credential-helper.cmd" "%USERPROFILE%\claude-code-with-bedrock\cowork-credential-helper.cmd" >nul
    echo OK Installed cowork-credential-helper.cmd
)

REM Copy Claude Code settings if they exist
if exist "claude-settings" (
    echo Copying Claude Code telemetry settings...
    if not exist "%USERPROFILE%\.claude" mkdir "%USERPROFILE%\.claude"

    REM Install managed-settings.json (organization-wide enforcement) if present
    if exist "claude-settings\managed-settings.json" (
        echo Managed settings detected [organization-wide enforcement]...

        REM Check for Administrator privileges
        net session >nul 2>&1
        if !errorlevel! neq 0 (
            echo ERROR: Managed settings require Administrator privileges.
            echo        Right-click install.bat and select "Run as administrator"
            echo        [Target: C:\Program Files\ClaudeCode\managed-settings.json]
            pause
            exit /b 1
        )

        REM Create managed-settings directory
        if not exist "C:\Program Files\ClaudeCode" mkdir "C:\Program Files\ClaudeCode"

        REM Replace placeholders and write managed settings
        powershell -Command "$otelPath = ($env:USERPROFILE + '\claude-code-with-bedrock\otel-helper.cmd').Replace('\','\\'); $credPath = $env:USERPROFILE + '\claude-code-with-bedrock\credential-process.exe' -replace '\\', '/'; (Get-Content 'claude-settings\managed-settings.json') -replace '__OTEL_HELPER_PATH__', $otelPath -replace '__CREDENTIAL_PROCESS_PATH__', $credPath | Set-Content 'C:\Program Files\ClaudeCode\managed-settings.json'"
        echo OK Managed settings installed: C:\Program Files\ClaudeCode\managed-settings.json
        echo    These settings have highest precedence and cannot be overridden by users.
    )

    REM Copy user-scope settings.json if present (with merge support)
    if exist "claude-settings\settings.json" (
        set WRITE_SETTINGS=false
        if exist "%USERPROFILE%\.claude\settings.json" (
            echo Existing Claude Code settings found - merging...

            REM Merge new settings into existing. Top-level keys from the new
            REM settings win, but the 'env' object is DEEP-merged so custom env
            REM vars the user added survive. $ErrorActionPreference=Stop plus
            REM the catch/exit 1 makes any failure visible via !errorlevel!.
            powershell -NoProfile -Command "$ErrorActionPreference = 'Stop'; try { $otelPath = ($env:USERPROFILE + '\claude-code-with-bedrock\otel-helper.cmd').Replace('\','\\'); $credPath = $env:USERPROFILE + '\claude-code-with-bedrock\credential-process.exe' -replace '\\', '/'; $settingsPath = Join-Path $env:USERPROFILE '.claude\settings.json'; $existing = Get-Content $settingsPath -Raw | ConvertFrom-Json; $incoming = (Get-Content 'claude-settings\settings.json' -Raw) -replace '__OTEL_HELPER_PATH__', $otelPath -replace '__CREDENTIAL_PROCESS_PATH__', $credPath | ConvertFrom-Json; foreach ($prop in $incoming.PSObject.Properties) { if ($prop.Name -eq 'env' -and $existing.PSObject.Properties['env']) { foreach ($envProp in $prop.Value.PSObject.Properties) { $existing.env | Add-Member -MemberType NoteProperty -Name $envProp.Name -Value $envProp.Value -Force } } else { $existing | Add-Member -MemberType NoteProperty -Name $prop.Name -Value $prop.Value -Force } }; $existing | ConvertTo-Json -Depth 10 | Set-Content $settingsPath } catch { Write-Error $_; exit 1 }"
            if !errorlevel! equ 0 (
                echo OK Claude Code settings merged [user settings preserved]
            ) else (
                set /p OVERWRITE="Merge failed. Overwrite with new settings? (y/n): "
                if /i "!OVERWRITE!"=="y" (
                    set WRITE_SETTINGS=true
                ) else (
                    echo Skipping Claude Code settings...
                )
            )
        ) else (
            set WRITE_SETTINGS=true
        )

        if "!WRITE_SETTINGS!"=="true" (
            REM No existing settings [or user chose overwrite] - write directly
            powershell -Command "$otelPath = ($env:USERPROFILE + '\claude-code-with-bedrock\otel-helper.cmd').Replace('\','\\'); $credPath = $env:USERPROFILE + '\claude-code-with-bedrock\credential-process.exe' -replace '\\', '/'; (Get-Content 'claude-settings\settings.json') -replace '__OTEL_HELPER_PATH__', $otelPath -replace '__CREDENTIAL_PROCESS_PATH__', $credPath | Set-Content (Join-Path $env:USERPROFILE '.claude\settings.json')"
            echo OK Claude Code settings configured
        )
    )
)

REM Configure AWS profiles
echo.
echo Configuring AWS profiles...

REM Read profiles from config.json using PowerShell
for /f %%p in ('powershell -NoProfile -Command "$c=Get-Content config.json|ConvertFrom-Json;$c.PSObject.Properties.Name"') do (
    echo Configuring AWS profile: %%p

    REM Get profile-specific region
    for /f %%r in ('powershell -NoProfile -Command "$c=Get-Content config.json|ConvertFrom-Json;$c.'"'"'%%p'"'"'.aws_region"') do set PROFILE_REGION=%%r

    if "!HAS_AWS_CLI!"=="1" (
        REM Use AWS CLI to configure profiles
        aws configure set credential_process "%USERPROFILE%\claude-code-with-bedrock\credential-process.exe --profile %%p" --profile %%p
        if !errorlevel! neq 0 (
            echo   ERROR: Failed to configure profile '%%p' via AWS CLI
        ) else (
            REM Set region
            if defined PROFILE_REGION (
                aws configure set region !PROFILE_REGION! --profile %%p
            ) else (
                aws configure set region us-east-2 --profile %%p
            )
            echo   OK Created AWS profile '%%p'

            REM Create a <profile>-collector profile for the otelcol sidecar. Runs only
            REM inside the HAS_AWS_CLI=1 branch above. otelcol resolves CloudWatch
            REM credentials via credential_process; a dedicated profile is used because a
            REM user's static ~/.aws/credentials would shadow credential_process on the
            REM main profile and cannot auto-refresh (see otel-helper.ps1).
            if exist "%USERPROFILE%\claude-code-with-bedrock\collector-config.yaml" (
                aws configure set credential_process "%USERPROFILE%\claude-code-with-bedrock\credential-process.exe --profile %%p" --profile %%p-collector
                if defined PROFILE_REGION (
                    aws configure set region !PROFILE_REGION! --profile %%p-collector
                ) else (
                    aws configure set region us-east-2 --profile %%p-collector
                )
                echo   OK Created AWS profile '%%p-collector' [otelcol SigV4 auth]
            )
        )
    ) else (
        REM No AWS CLI — write directly to ~/.aws/config using PowerShell.
        REM Also writes a <profile>-collector profile when a sidecar collector config is
        REM present, so otelcol can resolve CloudWatch creds via credential_process (the
        REM main profile's static ~/.aws/credentials would shadow it; see otel-helper.ps1).
        powershell -NoProfile -Command ^
            "$configDir = Join-Path $env:USERPROFILE '.aws';" ^
            "if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null };" ^
            "$configFile = Join-Path $configDir 'config';" ^
            "$profileName = '%%p';" ^
            "$region = if ('!PROFILE_REGION!' -ne '') { '!PROFILE_REGION!' } else { 'us-east-2' };" ^
            "$credProc = ($env:USERPROFILE + '\claude-code-with-bedrock\credential-process.exe --profile ' + $profileName) -replace '\', '/';" ^
            "$section = "`n[profile $profileName]`nregion = $region`ncredential_process = $credProc`n";" ^
            "$existing = if (Test-Path $configFile) { Get-Content $configFile -Raw } else { '' };" ^
            "if ($existing -notmatch "\[profile $profileName\]") { Add-Content -Path $configFile -Value $section; Write-Host '  OK Created AWS profile ''$profileName''' } else { Write-Host '  OK AWS profile ''$profileName'' already exists' };" ^
            "$collectorConfig = Join-Path $env:USERPROFILE 'claude-code-with-bedrock\collector-config.yaml';" ^
            "if (Test-Path $collectorConfig) { $collProfile = $profileName + '-collector'; $collSection = "`n[profile $collProfile]`nregion = $region`ncredential_process = $credProc`n"; $existing2 = if (Test-Path $configFile) { Get-Content $configFile -Raw } else { '' }; if ($existing2 -notmatch "\[profile $collProfile\]") { Add-Content -Path $configFile -Value $collSection; Write-Host '  OK Created AWS profile ''$collProfile'' [otelcol SigV4 auth]' } }"
    )
)


echo.
echo ======================================
echo Installation complete!
echo ======================================
echo.
echo Available profiles:
for /f %%p in ('powershell -NoProfile -Command "(Get-Content config.json | ConvertFrom-Json).PSObject.Properties.Name"') do (
    echo   - %%p
)
echo.
echo ^>^>^> Start Claude Code:
echo       claude
echo.
echo     Authentication is handled automatically via your configured credential
echo     process. Simply run 'claude' to start.
echo.
echo To use a non-default profile, set AWS_PROFILE before launching:
echo   set AWS_PROFILE=^<profile-name^>
echo   claude
echo.
pause
