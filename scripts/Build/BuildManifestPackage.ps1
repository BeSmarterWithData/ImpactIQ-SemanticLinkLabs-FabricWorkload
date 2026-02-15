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
    Whether to validate manifest files before packaging. Defaults to $false.

.EXAMPLE
    .\BuildManifestPackage.ps1
    
.EXAMPLE  
    .\BuildManifestPackage.ps1 -Environment "prod" -ValidateFiles $true

.NOTES
    Run this script from the scripts/Build directory
    Requires PowerShell 7+ and nuget executable
#>

param (
    [string]$Environment = "dev",
    [boolean]$ValidateFiles = $false
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

Write-Host "Building Nuget Package ..." -ForegroundColor Cyan
Write-Host ""

# Define paths
$scriptDir = $PSScriptRoot
$repoRoot = Join-Path $scriptDir "..\..\" | Resolve-Path
$workloadDir = Join-Path $repoRoot "Workload"
$manifestSourceDir = Join-Path $workloadDir "Manifest"
$outputDir = Join-Path $repoRoot "build\Manifest"

# Load environment variables
$envFile = Join-Path $workloadDir ".env.$Environment"
Write-Host "Loading configuration from: $envFile"

if (-not (Test-Path $envFile)) {
    Write-Host "❌ Environment file not found: $envFile" -ForegroundColor Red
    Write-Host "Please run SetupWorkload.ps1 first or specify a valid environment (dev, test, prod)." -ForegroundColor Yellow
    exit 1
}

$envVars = Load-EnvFile -EnvFilePath $envFile

if ($null -eq $envVars) {
    Write-Host "❌ Failed to load environment configuration" -ForegroundColor Red
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
    Write-Host "❌ WORKLOAD_NAME is not set in environment file" -ForegroundColor Red
    exit 1
}

if ([string]::IsNullOrWhiteSpace($workloadVersion)) {
    Write-Host "❌ WORKLOAD_VERSION is not set in environment file" -ForegroundColor Red
    exit 1
}

Write-Host "✅ Configuration loaded successfully" -ForegroundColor Green
Write-Host "  Workload Name: $workloadName" -ForegroundColor Cyan
Write-Host "  Version: $workloadVersion" -ForegroundColor Cyan
Write-Host "  Hosting Type: $workloadHostingType" -ForegroundColor Cyan
Write-Host ""

###############################################################################
# Create temp directory for building
###############################################################################
# Use a unique system temp folder to avoid file locking issues
$guid = [Guid]::NewGuid().ToString()
$tempPath = Join-Path ([System.IO.Path]::GetTempPath()) "Fabric_Manifest_Build_$guid"

Write-Host "Using temporary directory: $tempPath" -ForegroundColor Cyan
New-Item -ItemType Directory -Path $tempPath -Force | Out-Null

# Copy all manifest files to temp directory
Write-Host "Copying template files from $manifestSourceDir to $tempPath" -ForegroundColor Cyan
Copy-Item -Path "$manifestSourceDir\*" -Destination $tempPath -Recurse -Force

# Check if assets folder exists and report
$assetsPath = Join-Path $tempPath "assets"
if (Test-Path $assetsPath) {
    $assetFiles = Get-ChildItem -Path $assetsPath -Recurse -File
    Write-Host "✅ Copied $($assetFiles.Count) asset files (images, locales, etc.)" -ForegroundColor Green
}

###############################################################################
# Handle item files - move configured items to root directory
###############################################################################
$itemsPath = Join-Path $tempPath "items"
if (Test-Path $itemsPath) {
    # Parse ITEM_NAMES from environment variables (comma-separated list)
    $configuredItems = @()
    if ($envVars.ContainsKey('ITEM_NAMES') -and -not [string]::IsNullOrWhiteSpace($envVars['ITEM_NAMES'])) {
        $configuredItems = $envVars['ITEM_NAMES'] -split ',' | ForEach-Object { 
            $itemName = $_.Trim()
            # Add "Item" suffix to match folder naming convention if not present
            if (-not $itemName.EndsWith('Item')) {
                $itemName = $itemName + 'Item'
            }
            $itemName
        }
        Write-Host "Configured items from ITEM_NAMES: $($configuredItems -join ', ')" -ForegroundColor Cyan
    } else {
        # If ITEM_NAMES not configured, include all items found
        $allItemFolders = Get-ChildItem -Path $itemsPath -Directory
        $configuredItems = $allItemFolders | ForEach-Object { $_.Name }
        if ($configuredItems.Count -gt 0) {
            Write-Host "No ITEM_NAMES specified. Including all items found: $($configuredItems -join ', ')" -ForegroundColor Yellow
        }
    }
    
    if ($configuredItems.Count -gt 0) {
        $itemFiles = Get-ChildItem -Path $itemsPath -Recurse -Include "*.json", "*.xml" | Where-Object { $_.FullName -notlike "*\ItemDefinition\*" }
        
        # Filter to only include configured items
        $filteredItemFiles = $itemFiles | Where-Object {
            $itemFolderName = Split-Path (Split-Path $_.FullName -Parent) -Leaf
            $configuredItems -contains $itemFolderName
        }
        
        if ($filteredItemFiles.Count -gt 0) {
            Write-Host "Moving $($filteredItemFiles.Count) item configuration files to root directory..." -ForegroundColor Cyan
            
            foreach ($itemFile in $filteredItemFiles) {
                $destinationPath = Join-Path $tempPath $itemFile.Name
                
                # Handle duplicate names by adding item folder name as prefix
                if (Test-Path $destinationPath) {
                    $itemFolderName = Split-Path (Split-Path $itemFile.FullName -Parent) -Leaf
                    $destinationPath = Join-Path $tempPath "$itemFolderName$($itemFile.Name)"
                    Write-Host "  Renaming $($itemFile.Name) to $itemFolderName$($itemFile.Name) to avoid conflicts" -ForegroundColor Yellow
                }
                
                Move-Item -Path $itemFile.FullName -Destination $destinationPath -Force
                Write-Host "  ✅ Moved $($itemFile.Name)" -ForegroundColor Green
            }
        } else {
            Write-Host "No item configuration files found for configured items" -ForegroundColor Yellow
        }
    }
}
Write-Host ""

###############################################################################
# Replace placeholders in all files
###############################################################################
# Prepare replacements dictionary
$replacements = @{
    "WORKLOAD_NAME" = $workloadName
    "WORKLOAD_VERSION" = $workloadVersion
    "WORKLOAD_HOSTING_TYPE" = $workloadHostingType
    "FRONTEND_APPID" = $frontendAppId
    "FRONTEND_URL" = $frontendUrl
    "WORKLOAD_ID" = $workloadName  # Additional common placeholder
}

# Process all XML, JSON, and nuspec files to replace placeholders
$filesToProcess = Get-ChildItem -Path $tempPath -Recurse -Include "*.xml", "*.json", "*.nuspec"

Write-Host "Processing $($filesToProcess.Count) files for variable replacement..." -ForegroundColor Cyan
Write-Host "Binary files (images, etc.) are copied without modification." -ForegroundColor Cyan

foreach ($file in $filesToProcess) {
    $content = Get-Content $file.FullName -Raw -Encoding UTF8
    $originalContent = $content
    $replacedCount = 0
    
    # Replace environment variables with actual values
    foreach ($key in $replacements.Keys) {
        $placeholder = "{{$key}}"
        if ($content -match [regex]::Escape($placeholder)) {
            $content = $content -replace [regex]::Escape($placeholder), $replacements[$key]
            $replacedCount++
        }
    }
    
    # Replace MANIFEST_FOLDER with the current temp manifest folder path if present
    if ($content -match [regex]::Escape('{{MANIFEST_FOLDER}}')) {
        $content = $content -replace '\{\{MANIFEST_FOLDER\}\}', $tempPath
        $replacedCount++
    }
    
    # Only write if content changed
    if ($content -ne $originalContent) {
        Set-Content -Path $file.FullName -Value $content -Encoding UTF8 -NoNewline
        Write-Host "  ✅ Replaced $replacedCount placeholder(s) in $($file.Name)" -ForegroundColor Green
    }
}
Write-Host ""

###############################################################################
# Validate manifest files if requested
###############################################################################
if ($ValidateFiles -eq $true) {
    Write-Host "Validating processed configuration files..." -ForegroundColor Cyan
    
    # Check for validation scripts
    $validationScriptsDir = Join-Path $PSScriptRoot "Manifest\ValidationScripts"
    if (Test-Path $validationScriptsDir) {
        & "$validationScriptsDir\RemoveErrorFile.ps1" -outputDirectory $validationScriptsDir
        & "$validationScriptsDir\ManifestValidator.ps1" -inputDirectory $tempPath -inputXml "WorkloadManifest.xml" -inputXsd "WorkloadDefinition.xsd" -outputDirectory $validationScriptsDir
        & "$validationScriptsDir\ItemManifestValidator.ps1" -inputDirectory $tempPath -inputXsd "ItemDefinition.xsd" -workloadManifest "WorkloadManifest.xml" -outputDirectory $validationScriptsDir

        $validationErrorFile = Join-Path $validationScriptsDir "ValidationErrors.txt"
        if (Test-Path $validationErrorFile) {
            Write-Host "❌ Validation errors found. See $validationErrorFile" -ForegroundColor Red
            Get-Content $validationErrorFile | Write-Host
            # Cleanup temp directory before exit
            if (Test-Path $tempPath) {
                Remove-Item $tempPath -Recurse -Force -ErrorAction SilentlyContinue
            }
            exit 1
        }
        Write-Host "✅ Validation completed successfully" -ForegroundColor Green
    } else {
        Write-Host "⚠️  Validation scripts not found at $validationScriptsDir - skipping validation" -ForegroundColor Yellow
    }
    
    # Basic XML validation even if validation scripts don't exist
    $manifestXmlPath = Join-Path $tempPath "WorkloadManifest.xml"
    if (Test-Path $manifestXmlPath) {
        try {
            [xml]$xmlContent = Get-Content $manifestXmlPath
            Write-Host "✅ WorkloadManifest.xml is valid XML" -ForegroundColor Green
        } catch {
            Write-Host "❌ WorkloadManifest.xml is not valid XML: $($_.Exception.Message)" -ForegroundColor Red
            # Cleanup temp directory before exit
            if (Test-Path $tempPath) {
                Remove-Item $tempPath -Recurse -Force -ErrorAction SilentlyContinue
            }
            exit 1
        }
    }
    
    # Check if required files exist
    $requiredFiles = @(
        "WorkloadManifest.xml",
        "ManifestPackage.nuspec",
        "Product.json"
    )
    
    $missingFiles = @()
    foreach ($file in $requiredFiles) {
        $filePath = Join-Path $tempPath $file
        if (Test-Path $filePath) {
            Write-Host "  ✅ $file exists" -ForegroundColor Green
        } else {
            Write-Host "  ❌ $file is missing" -ForegroundColor Red
            $missingFiles += $file
        }
    }
    
    if ($missingFiles.Count -gt 0) {
        Write-Host "❌ Required files are missing: $($missingFiles -join ', ')" -ForegroundColor Red
        # Cleanup temp directory before exit
        if (Test-Path $tempPath) {
            Remove-Item $tempPath -Recurse -Force -ErrorAction SilentlyContinue
        }
        exit 1
    }
    
    Write-Host ""
}

###############################################################################
# Find NuGet executable and create package
###############################################################################
Write-Host "Locating NuGet executable..." -ForegroundColor Cyan
$nugetExe = $null

# Check if nuget is in node_modules (try both bin/ and parent directory)
$nodeModulesNuget = Join-Path $workloadDir "node_modules\nuget-bin\bin\nuget.exe"
$nodeModulesNugetAlt = Join-Path $workloadDir "node_modules\nuget-bin\nuget.exe"

if (Test-Path $nodeModulesNuget) {
    $nugetExe = $nodeModulesNuget
    Write-Host "✅ Found NuGet in node_modules/nuget-bin/bin" -ForegroundColor Green
} elseif (Test-Path $nodeModulesNugetAlt) {
    $nugetExe = $nodeModulesNugetAlt
    Write-Host "✅ Found NuGet in node_modules/nuget-bin" -ForegroundColor Green
}

# Check if nuget is in PATH
if ($null -eq $nugetExe) {
    try {
        $nugetCommand = Get-Command nuget -ErrorAction SilentlyContinue
        if ($nugetCommand) {
            $nugetExe = $nugetCommand.Source
            Write-Host "✅ Found NuGet in PATH" -ForegroundColor Green
        }
    } catch {
        # NuGet not in PATH
    }
}

if ($null -eq $nugetExe) {
    Write-Host "NuGet executable not found. Running npm install to get it..." -ForegroundColor Yellow
    try {
        Push-Location $workloadDir
        npm install
        
        # Run the install script manually if needed
        $installScript = Join-Path $workloadDir "node_modules\nuget-bin\install.js"
        if (Test-Path $installScript) {
            Write-Host "Running nuget-bin install script..." -ForegroundColor Yellow
            node $installScript
        }
    } finally {
        Pop-Location
    }
    
    # Check again after npm install
    if (Test-Path $nodeModulesNuget) {
        $nugetExe = $nodeModulesNuget
        Write-Host "✅ NuGet installed successfully" -ForegroundColor Green
    } elseif (Test-Path $nodeModulesNugetAlt) {
        $nugetExe = $nodeModulesNugetAlt
        Write-Host "✅ NuGet installed successfully" -ForegroundColor Green
    } else {
        Write-Host "❌ NuGet executable not found after npm install" -ForegroundColor Red
        # Cleanup temp directory before exit
        if (Test-Path $tempPath) {
            Remove-Item $tempPath -Recurse -Force -ErrorAction SilentlyContinue
        }
        exit 1
    }
}

Write-Host "Using NuGet: $nugetExe" -ForegroundColor Cyan
Write-Host ""

# Create output directory
Write-Host "Using output directory: $outputDir" -ForegroundColor Cyan
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

# Create NuGet package
Write-Host "Creating NuGet package..." -ForegroundColor Cyan
$nuspecPath = Join-Path $tempPath "ManifestPackage.nuspec"
$packageName = "$workloadName.$workloadVersion.nupkg"

if ($IsWindows) {
    & $nugetExe pack $nuspecPath -OutputDirectory $outputDir -Verbosity detailed
} else {
    # On Mac and Linux, check if mono is available
    $monoPath = Get-Command mono -ErrorAction SilentlyContinue
    if ($monoPath) {
        & mono $nugetExe pack $nuspecPath -OutputDirectory $outputDir -Verbosity detailed
    } else {
        Write-Host "❌ mono is required to run NuGet on Linux/Mac. Please install mono." -ForegroundColor Red
        Write-Host "Install with: sudo apt-get install mono-complete" -ForegroundColor Yellow
        # Cleanup temp directory before exit
        if (Test-Path $tempPath) {
            Remove-Item $tempPath -Recurse -Force -ErrorAction SilentlyContinue
        }
        exit 1
    }
}

if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ NuGet pack failed with exit code $LASTEXITCODE" -ForegroundColor Red
    # Cleanup temp directory before exit
    if (Test-Path $tempPath) {
        Remove-Item $tempPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    exit 1
}

# Verify package was created
$packagePath = Join-Path $outputDir $packageName
if (Test-Path $packagePath) {
    $packageSize = (Get-Item $packagePath).Length / 1MB
    Write-Host ""
    Write-Host "✅ Created the new ManifestPackage in $outputDir" -ForegroundColor Blue
    Write-Host "  Package: $packageName" -ForegroundColor Cyan
    Write-Host "  Location: $packagePath" -ForegroundColor Cyan
    Write-Host "  Size: $([math]::Round($packageSize, 2)) MB" -ForegroundColor Cyan
} else {
    Write-Host "❌ Package was not created" -ForegroundColor Red
    # Cleanup temp directory before exit
    if (Test-Path $tempPath) {
        Remove-Item $tempPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    exit 1
}

# Cleanup temp directory
if (Test-Path $tempPath) {
    Write-Host ""
    Write-Host "Cleaning up temporary directory..." -ForegroundColor Cyan
    Remove-Item $tempPath -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "✅ Cleanup completed" -ForegroundColor Green
}

Write-Host ""
Write-Host "✅ === Build completed successfully! ===" -ForegroundColor Blue
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Test the package with StartDevGateway.ps1" -ForegroundColor Cyan
Write-Host "  2. Deploy to Fabric tenant using the Admin Portal" -ForegroundColor Cyan
Write-Host ""
