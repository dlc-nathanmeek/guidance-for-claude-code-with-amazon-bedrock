@echo off
REM CoWork 3P credential helper - emits a Bedrock bearer token.
REM Invoked by Claude Desktop as inferenceCredentialHelper (no arguments).
"%~dp0credential-process.exe" --desktop --profile dlc-corporate-pilot-us-east-2
exit /b %errorlevel%
