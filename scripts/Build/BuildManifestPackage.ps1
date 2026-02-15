<#
.SYNOPSIS
    Builds the Microsoft Fabric Workload manifest package

.DESCRIPTION
    This script creates a NuGet package (.nupkg) containing the workload manifest and all required assets.
    It reads configuration from .env files, replaces placeholders in manifest files, and packages everything
    using NuGet.

.PARAMETER Environment
    The environment to build for (dev, test, or prod). Defaults to "dev".

.PARAMETER ValidateFiles
    Whether to validate manifest files before packaging. Defaults to $true.

.PARAMETER Force
    Force rebuild even if package already exists. Defaults to $false.

.EXAMPLE
    .\BuildManifestPackage.ps1
    
.EXAMPLE  
    .\BuildManifestPackage.ps1 -Environment "prod" -Force $true

.NOTES
    Run this script from the scripts/Build directory
    Requires PowerShell 7+ and nuget executable
#>

param (
    [string]$Environment = "dev",
    [boolean]$ValidateFiles = $true,
    [boolean]$Force = $false
)

# Check for PowerShell 7+
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Error "This script requires PowerShell 7 or later. Please install PowerShell 7+ (https://aka.ms/powershell) and try again."
    exit 1
}

###############################################################################
# Helper Functions
###############################################################################

function Write-Info {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "✅ $Message" -ForegroundColor Green
}

function Write-ErrorMessage {
    param([string]$Message)
    Write-Host "❌ $Message" -ForegroundColor Red
}

function Load-EnvFile {
    param([string]$EnvFilePath)
    
    if (-not (Test-Path $EnvFilePath)) {
        Write-ErrorMessage "Environment file not found: $EnvFilePath"
        return $null
    }
    
    $envVars = @{}
    Get-Content $EnvFilePath | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith("#")) {
            $parts = $line -split "=", 2
            if ($parts.Count -eq 2) {
                $key = $parts[0].Trim()
                $value = $parts[1].Trim()
                $envVars[$key] = $value
            }
        }
    }
    
    return $envVars
}

function Replace-Placeholders {
    param(
        [string]$Content,
        [hashtable]$Replacements
    )
    
    $result = $Content
    foreach ($key in $Replacements.Keys) {
        $placeholder = "{{$key}}"
        $value = $Replacements[$key]
        $result = $result -replace [regex]::Escape($placeholder), $value
    }
    
    return $result
}

###############################################################################
# Main Script
###############################################################################

Write-Info "=== Building Manifest Package ==="
Write-Host ""

# Define paths
$scriptDir = $PSScriptRoot
$repoRoot = Join-Path $scriptDir "..\..\" | Resolve-Path
$workloadDir = Join-Path $repoRoot "Workload"
$manifestSourceDir = Join-Path $workloadDir "Manifest"
$buildDir = Join-Path $repoRoot "build"
$manifestBuildDir = Join-Path $buildDir "Manifest"

Write-Info "Repository root: $repoRoot"
Write-Info "Manifest source: $manifestSourceDir"
Write-Info "Build directory: $manifestBuildDir"
Write-Host ""

# Load environment variables
$envFile = Join-Path $workloadDir ".env.$Environment"
Write-Info "Loading configuration from: $envFile"
$envVars = Load-EnvFile -EnvFilePath $envFile

if ($null -eq $envVars) {
    Write-ErrorMessage "Failed to load environment configuration"
    exit 1
}

# Extract required variables
$workloadName = $envVars["WORKLOAD_NAME"]
$workloadVersion = $envVars["WORKLOAD_VERSION"]
$workloadHostingType = $envVars["WORKLOAD_HOSTING_TYPE"]
$frontendAppId = $envVars["FRONTEND_APPID"]
$frontendUrl = $envVars["FRONTEND_URL"]

# Validate required variables
if ([string]::IsNullOrWhiteSpace($workloadName)) {
    Write-ErrorMessage "WORKLOAD_NAME is not set in environment file"
    exit 1
}

if ([string]::IsNullOrWhiteSpace($workloadVersion)) {
    Write-ErrorMessage "WORKLOAD_VERSION is not set in environment file"
    exit 1
}

Write-Success "Configuration loaded successfully"
Write-Info "  Workload Name: $workloadName"
Write-Info "  Version: $workloadVersion"
Write-Info "  Hosting Type: $workloadHostingType"
Write-Host ""

# Create build directory structure
Write-Info "Creating build directory structure..."
if (Test-Path $manifestBuildDir) {
    if ($Force) {
        Remove-Item $manifestBuildDir -Recurse -Force
    } else {
        Write-Warning "Build directory already exists. Use -Force to rebuild."
    }
}

New-Item -ItemType Directory -Path $manifestBuildDir -Force | Out-Null
Write-Success "Build directory created: $manifestBuildDir"
Write-Host ""

# Copy all manifest files to build directory
Write-Info "Copying manifest files..."
Copy-Item -Path "$manifestSourceDir\*" -Destination $manifestBuildDir -Recurse -Force
Write-Success "Manifest files copied"
Write-Host ""

# Prepare replacements dictionary
$replacements = @{
    "WORKLOAD_NAME" = $workloadName
    "WORKLOAD_VERSION" = $workloadVersion
    "WORKLOAD_HOSTING_TYPE" = $workloadHostingType
    "FRONTEND_APPID" = $frontendAppId
    "FRONTEND_URL" = $frontendUrl
}

# Replace placeholders in WorkloadManifest.xml
Write-Info "Processing WorkloadManifest.xml..."
$manifestXmlPath = Join-Path $manifestBuildDir "WorkloadManifest.xml"
if (Test-Path $manifestXmlPath) {
    $manifestContent = Get-Content $manifestXmlPath -Raw -Encoding UTF8
    $manifestContent = Replace-Placeholders -Content $manifestContent -Replacements $replacements
    Set-Content -Path $manifestXmlPath -Value $manifestContent -Encoding UTF8 -NoNewline
    Write-Success "WorkloadManifest.xml processed"
} else {
    Write-ErrorMessage "WorkloadManifest.xml not found"
    exit 1
}

# Replace placeholders in ManifestPackage.nuspec
Write-Info "Processing ManifestPackage.nuspec..."
$nuspecPath = Join-Path $manifestBuildDir "ManifestPackage.nuspec"
if (Test-Path $nuspecPath) {
    $nuspecContent = Get-Content $nuspecPath -Raw -Encoding UTF8
    $nuspecContent = Replace-Placeholders -Content $nuspecContent -Replacements $replacements
    Set-Content -Path $nuspecPath -Value $nuspecContent -Encoding UTF8 -NoNewline
    Write-Success "ManifestPackage.nuspec processed"
} else {
    Write-ErrorMessage "ManifestPackage.nuspec not found"
    exit 1
}

# Replace placeholders in Product.json if it exists
$productJsonPath = Join-Path $manifestBuildDir "Product.json"
if (Test-Path $productJsonPath) {
    Write-Info "Processing Product.json..."
    $productContent = Get-Content $productJsonPath -Raw -Encoding UTF8
    $productContent = Replace-Placeholders -Content $productContent -Replacements $replacements
    Set-Content -Path $productJsonPath -Value $productContent -Encoding UTF8 -NoNewline
    Write-Success "Product.json processed"
}

Write-Host ""

# Validate manifest files if requested
if ($ValidateFiles) {
    Write-Info "Validating manifest files..."
    
    # Check if WorkloadManifest.xml is valid XML
    try {
        [xml]$xmlContent = Get-Content $manifestXmlPath
        Write-Success "WorkloadManifest.xml is valid XML"
    } catch {
        Write-ErrorMessage "WorkloadManifest.xml is not valid XML: $($_.Exception.Message)"
        exit 1
    }
    
    # Check if required files exist
    $requiredFiles = @(
        "WorkloadManifest.xml",
        "ManifestPackage.nuspec",
        "Product.json"
    )
    
    foreach ($file in $requiredFiles) {
        $filePath = Join-Path $manifestBuildDir $file
        if (Test-Path $filePath) {
            Write-Success "$file exists"
        } else {
            Write-ErrorMessage "$file is missing"
            exit 1
        }
    }
    
    Write-Host ""
}

# Find NuGet executable
Write-Info "Locating NuGet executable..."
$nugetExe = $null

# Check if nuget is in node_modules
$nodeModulesNuget = Join-Path $workloadDir "node_modules\nuget-bin\bin\nuget.exe"
if (Test-Path $nodeModulesNuget) {
    $nugetExe = $nodeModulesNuget
    Write-Success "Found NuGet in node_modules"
}

# Check if nuget is in PATH
if ($null -eq $nugetExe) {
    try {
        $nugetCommand = Get-Command nuget -ErrorAction SilentlyContinue
        if ($nugetCommand) {
            $nugetExe = $nugetCommand.Source
            Write-Success "Found NuGet in PATH"
        }
    } catch {
        # NuGet not in PATH
    }
}

if ($null -eq $nugetExe) {
    Write-ErrorMessage "NuGet executable not found. Please run 'npm install' in the Workload directory first."
    exit 1
}

Write-Info "Using NuGet: $nugetExe"
Write-Host ""

# Create NuGet package
Write-Info "Creating NuGet package..."
$packageName = "$workloadName.$workloadVersion.nupkg"
$packagePath = Join-Path $manifestBuildDir $packageName

Push-Location $manifestBuildDir
try {
    if ($IsWindows) {
        & $nugetExe pack ManifestPackage.nuspec -OutputDirectory . -NoPackageAnalysis
    } else {
        # On Linux/Mac, use mono if available, otherwise try dotnet
        $monoPath = Get-Command mono -ErrorAction SilentlyContinue
        if ($monoPath) {
            & mono $nugetExe pack ManifestPackage.nuspec -OutputDirectory . -NoPackageAnalysis
        } else {
            # Try running with wine as fallback (some systems have it)
            $winePath = Get-Command wine -ErrorAction SilentlyContinue
            if ($winePath) {
                & wine $nugetExe pack ManifestPackage.nuspec -OutputDirectory . -NoPackageAnalysis
            } else {
                Write-ErrorMessage "NuGet requires mono or wine on non-Windows systems. Please install mono."
                exit 1
            }
        }
    }
    
    if ($LASTEXITCODE -ne 0) {
        Write-ErrorMessage "NuGet pack failed with exit code $LASTEXITCODE"
        exit 1
    }
} finally {
    Pop-Location
}

# Verify package was created
if (Test-Path $packagePath) {
    $packageSize = (Get-Item $packagePath).Length / 1MB
    Write-Success "Package created successfully!"
    Write-Info "  Package: $packageName"
    Write-Info "  Location: $packagePath"
    Write-Info "  Size: $([math]::Round($packageSize, 2)) MB"
} else {
    Write-ErrorMessage "Package was not created"
    exit 1
}

Write-Host ""
Write-Success "=== Build completed successfully! ==="
Write-Host ""
Write-Info "Next steps:"
Write-Info "  1. Test the package with StartDevGateway.ps1"
Write-Info "  2. Deploy to Fabric tenant using the Admin Portal"
Write-Host ""
