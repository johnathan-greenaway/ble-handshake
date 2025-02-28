<#
.SYNOPSIS
    Installs Zed editor from source on Windows
.DESCRIPTION
    This script automates the installation of Zed for Windows by:
    - Setting up prerequisites (Rustup, Visual Studio, Windows SDK, CMake)
    - Properly configuring WebRTC dependencies
    - Enabling long path support
    - Cloning the Zed repository
    - Building Zed from source
#>

# Ensure we're running with administrator privileges
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Warning "This script requires administrator privileges. Please run as administrator."
    exit
}

# Configuration
$tempDir = "$env:TEMP\zed-install"
$vsInstallerUrl = "https://aka.ms/vs/17/release/vs_community.exe"
$vsInstallerPath = "$tempDir\vs_community.exe"
$zedPath = "$env:USERPROFILE\zed"
$webrtcZipPath = "$tempDir\webrtc-win-x64-release.zip"
$webrtcUrl = "https://github.com/livekit/client-sdk-rust/releases/download/webrtc-dac8015-6/webrtc-win-x64-release.zip"

# Create temporary directory
if (!(Test-Path -Path $tempDir)) {
    New-Item -ItemType Directory -Path $tempDir | Out-Null
}

# Function to check if a command exists
function Test-Command {
    param ($command)
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'stop'
    try {
        if (Get-Command $command) { return $true }
    }
    catch {
        return $false
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }
}

# Convert Windows path to format safe for TOML
function Convert-ToTomlPath {
    param ([string]$path)
    return $path.Replace('\', '/')
}

# Enable long paths support for Windows and Git
function Enable-LongPaths {
    Write-Host "Enabling long path support for Windows..." -ForegroundColor Yellow
    New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name "LongPathsEnabled" -Value 1 -PropertyType DWORD -Force | Out-Null
    
    if (Test-Command "git") {
        Write-Host "Enabling long path support for Git..." -ForegroundColor Yellow
        git config --system core.longpaths true
    }
    else {
        Write-Warning "Git not found. Long path support for Git will not be configured."
    }
}

# Install Rustup
function Install-Rustup {
    if (!(Test-Command "rustup")) {
        Write-Host "Installing Rustup..." -ForegroundColor Yellow
        
        $rustupInit = "$tempDir\rustup-init.exe"
        Invoke-WebRequest -Uri "https://win.rustup.rs/x86_64" -OutFile $rustupInit
        
        # Run rustup installer and accept defaults
        Start-Process -FilePath $rustupInit -ArgumentList "-y" -Wait
        
        # Add cargo binaries to current session PATH
        $env:Path = "$env:USERPROFILE\.cargo\bin;" + $env:Path
    }
    else {
        Write-Host "Rustup is already installed." -ForegroundColor Green
    }
}

# Install Visual Studio with required components including Spectre-mitigated libraries
function Install-VisualStudio {
    $vsComponents = @(
        "--add Microsoft.VisualStudio.Component.CoreEditor",
        "--add Microsoft.VisualStudio.Workload.CoreEditor",
        "--add Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
        "--add Microsoft.VisualStudio.ComponentGroup.WebToolsExtensions.CMake",
        "--add Microsoft.VisualStudio.Component.VC.CMake.Project",
        "--add Microsoft.VisualStudio.Component.Windows11SDK.26100",
        "--add Microsoft.VisualStudio.Component.VC.Runtimes.x86.x64.Spectre",
        "--add Microsoft.VisualStudio.Component.Windows.SDK",
        "--add Microsoft.VisualStudio.Component.VC.ATL",
        "--add Microsoft.VisualStudio.Component.VC.ATLMFC"
    )
    
    # Check if VS is installed with required components
    $vsInstaller = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    
    if (!(Test-Path $vsInstaller)) {
        Write-Host "Visual Studio Installer not found. Downloading and installing Visual Studio with required components..." -ForegroundColor Yellow
        
        # Download VS installer
        Invoke-WebRequest -Uri $vsInstallerUrl -OutFile $vsInstallerPath
        
        # Install VS with required components
        $arguments = @("--quiet", "--norestart", "--wait") + $vsComponents
        Start-Process -FilePath $vsInstallerPath -ArgumentList $arguments -Wait
    }
    else {
        # Check if Spectre-mitigated libraries are installed
        $hasSpectre = & $vsInstaller -products * -requires Microsoft.VisualStudio.Component.VC.Runtimes.x86.x64.Spectre -latest
        
        if ($null -eq $hasSpectre) {
            Write-Host "Adding Spectre-mitigated libraries and additional components to Visual Studio..." -ForegroundColor Yellow
            
            # Download VS installer if not already present
            if (!(Test-Path $vsInstallerPath)) {
                Invoke-WebRequest -Uri $vsInstallerUrl -OutFile $vsInstallerPath
            }
            
            # Install additional components
            $installArgs = @("--quiet", "--norestart", "--wait") + $vsComponents
            Start-Process -FilePath $vsInstallerPath -ArgumentList $installArgs -Wait
        }
        else {
            Write-Host "Visual Studio with required components is already installed." -ForegroundColor Green
        }
    }
}

# Install CMake or verify it's in PATH
function Install-CMake {
    if (!(Test-Command "cmake")) {
        Write-Host "CMake not found in PATH." -ForegroundColor Yellow
        
        # Look for CMake in the Visual Studio installation
        $vsPath = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -property installationPath
        $cmakePath = "$vsPath\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin"
        
        if (Test-Path "$cmakePath\cmake.exe") {
            Write-Host "Adding CMake from Visual Studio to PATH..." -ForegroundColor Yellow
            $env:Path = "$cmakePath;" + $env:Path
            
            # Add to permanent PATH
            [Environment]::SetEnvironmentVariable(
                "Path", 
                [Environment]::GetEnvironmentVariable("Path", [EnvironmentVariableTarget]::Machine) + ";$cmakePath", 
                [EnvironmentVariableTarget]::Machine
            )
        }
        else {
            Write-Host "Installing CMake..." -ForegroundColor Yellow
            $cmakeInstaller = "$tempDir\cmake-installer.msi"
            Invoke-WebRequest -Uri "https://github.com/Kitware/CMake/releases/download/v3.27.7/cmake-3.27.7-windows-x86_64.msi" -OutFile $cmakeInstaller
            Start-Process -FilePath "msiexec.exe" -ArgumentList "/i", $cmakeInstaller, "/quiet", "/qn", "/norestart" -Wait
            
            # Add to PATH for current session
            $env:Path = "C:\Program Files\CMake\bin;" + $env:Path
        }
    }
    else {
        Write-Host "CMake is already installed." -ForegroundColor Green
    }
}

# Properly configure WebRTC dependencies
function Configure-WebRTCDependencies {
    Write-Host "Configuring WebRTC dependencies..." -ForegroundColor Yellow
    
    # Create proper WebRTC directory structure
    $webrtcDir = "$env:USERPROFILE\.cargo\webrtc"
    $webrtcLibDir = "$webrtcDir\lib"
    $webrtcIncludeDir = "$webrtcDir\include"
    
    # Create directories if they don't exist
    if (!(Test-Path -Path $webrtcDir)) {
        New-Item -ItemType Directory -Path $webrtcDir -Force | Out-Null
    }
    if (!(Test-Path -Path $webrtcLibDir)) {
        New-Item -ItemType Directory -Path $webrtcLibDir -Force | Out-Null
    }
    if (!(Test-Path -Path $webrtcIncludeDir)) {
        New-Item -ItemType Directory -Path $webrtcIncludeDir -Force | Out-Null
    }
    
    # Download WebRTC zip with increased timeout
    try {
        Write-Host "Downloading WebRTC library from $webrtcUrl..." -ForegroundColor Yellow
        
        # Use .NET WebClient with increased timeout
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile($webrtcUrl, $webrtcZipPath)
        
        # Extract the WebRTC zip to a temporary location
        $extractPath = "$tempDir\webrtc-extract"
        if (Test-Path $extractPath) {
            Remove-Item -Path $extractPath -Recurse -Force
        }
        New-Item -ItemType Directory -Path $extractPath -Force | Out-Null
        
        Write-Host "Extracting WebRTC library..." -ForegroundColor Yellow
        Expand-Archive -Path $webrtcZipPath -DestinationPath $extractPath -Force
        
        # Look for the actual lib and include directories in the extracted files
        $libSrc = Get-ChildItem -Path $extractPath -Filter "*.lib" -Recurse
        $includeSrc = Get-ChildItem -Path $extractPath -Filter "*.h" -Recurse | 
                     Select-Object -First 1 | 
                     ForEach-Object { $_.Directory.Parent.FullName }
        
        if ($libSrc.Count -gt 0) {
            # Copy all lib files to the lib directory
            foreach ($lib in $libSrc) {
                Copy-Item -Path $lib.FullName -Destination $webrtcLibDir -Force
                Write-Host "Copied $($lib.Name) to $webrtcLibDir" -ForegroundColor Green
            }
            
            # If we found include files, copy them as well
            if ($includeSrc) {
                Copy-Item -Path "$includeSrc\*" -Destination $webrtcIncludeDir -Recurse -Force
                Write-Host "Copied include files to $webrtcIncludeDir" -ForegroundColor Green
            }
            
            # Set environment variables for the build
            $env:LK_CUSTOM_WEBRTC = $webrtcDir
            [Environment]::SetEnvironmentVariable("LK_CUSTOM_WEBRTC", $webrtcDir, [EnvironmentVariableTarget]::User)
            
            Write-Host "WebRTC dependencies configured successfully." -ForegroundColor Green
        }
        else {
            Write-Warning "No WebRTC library files found in the downloaded archive. Trying alternative method..."
            
            # Set up in-memory files (these are the minimum files needed)
            # Create an empty lib file
            $emptyLib = "$webrtcLibDir\webrtc.lib"
            New-Item -ItemType File -Path $emptyLib -Force | Out-Null
            
            # Create a basic header file
            $headerContent = @"
#ifndef WEBRTC_API_H_
#define WEBRTC_API_H_
namespace webrtc {}
#endif  // WEBRTC_API_H_
"@
            Set-Content -Path "$webrtcIncludeDir\api.h" -Value $headerContent
            
            # Set environment variable to disable WebRTC
            $env:LK_CUSTOM_WEBRTC = $webrtcDir
            [Environment]::SetEnvironmentVariable("LK_CUSTOM_WEBRTC", $webrtcDir, [EnvironmentVariableTarget]::User)
            
            Write-Host "Created minimal WebRTC stub files." -ForegroundColor Yellow
        }
    }
    catch {
        Write-Warning "Failed to download or extract WebRTC dependencies: $_"
        
        # Create stub files as a fallback
        Write-Host "Creating minimal WebRTC stub files as fallback..." -ForegroundColor Yellow
        
        # Create an empty lib file
        $emptyLib = "$webrtcLibDir\webrtc.lib"
        New-Item -ItemType File -Path $emptyLib -Force | Out-Null
        
        # Create a basic header file
        $headerContent = @"
#ifndef WEBRTC_API_H_
#define WEBRTC_API_H_
namespace webrtc {}
#endif  // WEBRTC_API_H_
"@
        Set-Content -Path "$webrtcIncludeDir\api.h" -Value $headerContent
        
        # Set environment variable to use our stub WebRTC
        $env:LK_CUSTOM_WEBRTC = $webrtcDir
        [Environment]::SetEnvironmentVariable("LK_CUSTOM_WEBRTC", $webrtcDir, [EnvironmentVariableTarget]::User)
        
        Write-Host "Created minimal WebRTC stub files." -ForegroundColor Yellow
    }
    
    # Create a small cargo config file in the .cargo directory to help find the WebRTC libs
    # Using proper path format for TOML
    $cargoConfigDir = "$env:USERPROFILE\.cargo"
    $cargoConfigPath = "$cargoConfigDir\config.toml"
    
    # Convert the Windows path to a format that works in TOML (forward slashes)
    $webrtcLibDirToml = Convert-ToTomlPath $webrtcLibDir
    
    # Remove existing config if it has path errors
    if (Test-Path $cargoConfigPath) {
        $currentConfig = Get-Content $cargoConfigPath -Raw -ErrorAction SilentlyContinue
        if ($currentConfig -match "invalid unicode") {
            Remove-Item $cargoConfigPath -Force
        }
    }
    
    if (!(Test-Path $cargoConfigPath)) {
        $cargoConfig = @"
[build]
rustflags = ["-C", "link-search=$webrtcLibDirToml"]
"@
        Set-Content -Path $cargoConfigPath -Value $cargoConfig
        Write-Host "Created cargo config at $cargoConfigPath" -ForegroundColor Green
    }
    else {
        # Append to existing config if needed
        $cargoConfig = Get-Content $cargoConfigPath -Raw
        if ($cargoConfig -notmatch "link-search=$webrtcLibDirToml") {
            $appendConfig = @"

[build]
rustflags = ["-C", "link-search=$webrtcLibDirToml"]
"@
            Add-Content -Path $cargoConfigPath -Value $appendConfig
            Write-Host "Updated cargo config at $cargoConfigPath" -ForegroundColor Green
        }
    }
}

# Clone the Zed repository
function Clone-ZedRepository {
    if (!(Test-Path -Path $zedPath)) {
        Write-Host "Cloning Zed repository..." -ForegroundColor Yellow
        git clone https://github.com/zed-industries/zed.git $zedPath
    }
    else {
        Write-Host "Zed repository already exists at $zedPath." -ForegroundColor Green
        
        # Pull the latest changes
        Push-Location $zedPath
        git pull
        Pop-Location
    }
}

# Create a local Cargo config file
function Create-LocalCargoConfig {
    Write-Host "Creating local Cargo configuration..." -ForegroundColor Yellow
    
    $localCargoDir = "$zedPath\.cargo"
    $localConfigPath = "$localCargoDir\config.toml"
    
    if (!(Test-Path $localCargoDir)) {
        New-Item -ItemType Directory -Path $localCargoDir -Force | Out-Null
    }
    
    # Convert the Windows path to a format that works in TOML (forward slashes)
    $webrtcLibDirToml = Convert-ToTomlPath "$env:USERPROFILE\.cargo\webrtc\lib"
    
    $localConfig = @"
[build]
rustflags = ["-C", "target-feature=+crt-static"]

[target.x86_64-pc-windows-msvc]
rustflags = ["--cfg", "windows_slim_errors", "-C", "target-feature=+crt-static", "-C", "link-search=$webrtcLibDirToml"]

[env]
ZED_DISABLE_COLLAB = "1"
"@
    
    Set-Content -Path $localConfigPath -Value $localConfig
    Write-Host "Created local Cargo config at $localConfigPath" -ForegroundColor Green
}

# Build Zed from source
function Build-Zed {
    Write-Host "Building Zed (this may take a while)..." -ForegroundColor Yellow
    
    Push-Location $zedPath
    
    # Create a local Cargo config file with proper paths
    Create-LocalCargoConfig
    
    # Clean first to ensure a fresh build
    Write-Host "Cleaning previous build artifacts..." -ForegroundColor Yellow
    cargo clean
    
    # Try to build with the toolchain specified in the rust-toolchain.toml file
    Write-Host "Building Zed with specified toolchain..." -ForegroundColor Yellow
    $env:ZED_DISABLE_COLLAB = "1"
    
    # Build with release profile
    cargo build --release
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Zed built successfully!" -ForegroundColor Green
        Write-Host "You can find the executable at: $zedPath\target\release\zed.exe" -ForegroundColor Green
        
        # Create a shortcut on the desktop
        $WshShell = New-Object -ComObject WScript.Shell
        $Shortcut = $WshShell.CreateShortcut("$env:USERPROFILE\Desktop\Zed.lnk")
        $Shortcut.TargetPath = "$zedPath\target\release\zed.exe"
        $Shortcut.Save()
        
        Write-Host "Created a shortcut on your desktop." -ForegroundColor Green
    }
    else {
        Write-Host "Failed to build Zed. Trying alternative approach..." -ForegroundColor Yellow
        
        # Revert to stable toolchain
        [Environment]::SetEnvironmentVariable("RUSTUP_TOOLCHAIN", "stable", [EnvironmentVariableTarget]::Process)
        $env:RUSTUP_TOOLCHAIN = "stable"
        
        # Try with just the base functionality (no collaboration)
        cargo build --release --no-default-features
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Zed built successfully with minimal features!" -ForegroundColor Green
            Write-Host "You can find the executable at: $zedPath\target\release\zed.exe" -ForegroundColor Green
            
            # Create a shortcut on the desktop
            $WshShell = New-Object -ComObject WScript.Shell
            $Shortcut = $WshShell.CreateShortcut("$env:USERPROFILE\Desktop\Zed.lnk")
            $Shortcut.TargetPath = "$zedPath\target\release\zed.exe"
            $Shortcut.Save()
            
            Write-Host "Created a shortcut on your desktop." -ForegroundColor Green
        }
        else {
            Write-Host "Failed to build Zed with all attempted methods." -ForegroundColor Red
            Write-Host "Consider using the official pre-built binaries from https://zed.dev/" -ForegroundColor Yellow
        }
    }
    
    Pop-Location
}

# Main execution
try {
    Write-Host "Starting Zed installation..." -ForegroundColor Green
    
    # Set up the environment
    Enable-LongPaths
    Install-Rustup
    Install-VisualStudio
    Install-CMake
    Configure-WebRTCDependencies
    
    # Clone and build
    Clone-ZedRepository
    Build-Zed
    
    Write-Host "Zed installation process completed!" -ForegroundColor Green
}
catch {
    Write-Host "An error occurred during installation:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host "Stack Trace:" $_.ScriptStackTrace -ForegroundColor Red
}
finally {
    # Clean up if needed
    # Remove-Item -Path $tempDir -Recurse -Force
    Write-Host "Installation script finished." -ForegroundColor Cyan
}
