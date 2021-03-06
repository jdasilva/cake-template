##########################################################################
# This is the Cake bootstrapper script for PowerShell.
# This file was downloaded from https://github.com/silverlake-pub/cake-template
# Feel free to change this file to fit your needs.
##########################################################################

<#

.SYNOPSIS
This is a Powershell script to bootstrap a Cake build.

.DESCRIPTION
This Powershell script will download NuGet if missing, restore NuGet tools (including Cake)
and execute your Cake build script with the parameters you provide.

.PARAMETER Script
The build script to execute.
.PARAMETER Target
The build script target to run.
.PARAMETER Configuration
The build configuration to use.
.PARAMETER Verbosity
Specifies the amount of information to be displayed.
.PARAMETER ShowDescription
Shows description about tasks.
.PARAMETER DryRun
Performs a dry run.
.PARAMETER Experimental
Uses the nightly builds of the Roslyn script engine.
.PARAMETER Mono
Uses the Mono Compiler rather than the Roslyn script engine.
.PARAMETER SkipToolPackageRestore
Skips restoring of packages.
.PARAMETER ScriptArgs
Remaining arguments are added here.

.LINK
https://cakebuild.net

#>

[CmdletBinding()]
Param(
    [string]$Script = "build.cake",
    [string]$Target,
    [string]$Configuration,
    [ValidateSet("Quiet", "Minimal", "Normal", "Verbose", "Diagnostic")]
    [string]$Verbosity,
    [switch]$ShowDescription,
    [Alias("WhatIf", "Noop")]
    [switch]$DryRun,    
    [switch]$Experimental,
    [switch]$Mono,
    [switch]$SkipToolPackageRestore,
    [Parameter(Position=0,Mandatory=$false,ValueFromRemainingArguments=$true)]
    [string[]]$ScriptArgs
)

# Define sources
$NUGET_SOURCE = if ($env:NUGET_SOURCE -eq $null) { "https://www.nuget.org/api/v2" } else { $env:NUGET_SOURCE }
$NUGET_VERSION = "4.4.1"
$TEMPLATE_URL = "https://raw.githubusercontent.com/silverlake-pub/cake-template/master"

[Reflection.Assembly]::LoadWithPartialName("System.Security") | Out-Null
function MD5HashFile([string] $filePath)
{
    if ([string]::IsNullOrEmpty($filePath) -or !(Test-Path $filePath -PathType Leaf))
    {
        return $null
    }

    [System.IO.Stream] $file = $null;
    [System.Security.Cryptography.MD5] $md5 = $null;
    try
    {
        $md5 = [System.Security.Cryptography.MD5]::Create()
        $file = [System.IO.File]::OpenRead($filePath)
        return [System.BitConverter]::ToString($md5.ComputeHash($file))
    }
    finally
    {
        if ($file -ne $null)
        {
            $file.Dispose()
        }
    }
}

# Sources:
# http://stackoverflow.com/a/19132572/287602
function SwitchToCRLFLineEndings([string] $filePath)
{
    $text = [IO.File]::ReadAllText($filePath) -replace "`r`n", "`n"
    $text = $text -replace "`n", "`r`n"
    [IO.File]::WriteAllText($filePath, $text)
}

Write-Host "Preparing to run build script..."

if(!$PSScriptRoot){
    $PSScriptRoot = Split-Path $MyInvocation.MyCommand.Path -Parent
}

$TOOLS_DIR = Join-Path $PSScriptRoot "tools"
$ADDINS_DIR = Join-Path $TOOLS_DIR "Addins"
$MODULES_DIR = Join-Path $TOOLS_DIR "Modules"
$UNZIP_EXE = Join-Path $TOOLS_DIR "win32/unzip.exe"
$NUGET_EXE = Join-Path $TOOLS_DIR "nuget.exe"
$CAKE_EXE = Join-Path $TOOLS_DIR "Cake/Cake.exe"
$PACKAGES_CONFIG = Join-Path $TOOLS_DIR "packages.config"
$PACKAGES_CONFIG_MD5 = Join-Path $TOOLS_DIR "packages.config.md5sum"
$ADDINS_PACKAGES_CONFIG = Join-Path $ADDINS_DIR "packages.config"
$MODULES_PACKAGES_CONFIG = Join-Path $MODULES_DIR "packages.config"

# Make sure tools folder exists
if ((Test-Path $PSScriptRoot) -and !(Test-Path $TOOLS_DIR)) {
    Write-Verbose -Message "Creating tools directory..."
    New-Item -Path $TOOLS_DIR -Type directory | out-null
}

# Bootstrap cake build files if packages.config doesn't exist
if (!(Test-Path $PACKAGES_CONFIG)) {
    Write-Verbose -Message "Downloading bootstrap files..."
    try
    {
        $thisScriptPath = (Join-Path $PSScriptRoot "build.ps1")
        $thisScriptHash = MD5HashFile $thisScriptPath
        $webClient = (New-Object System.Net.WebClient);
        $webClient.DownloadFile($TEMPLATE_URL + "/tools/packages.config", $PACKAGES_CONFIG);
        SwitchToCRLFLineEndings $PACKAGES_CONFIG
        $gitIgnorePath = Join-Path $TOOLS_DIR ".gitignore";
        $webClient.DownloadFile($TEMPLATE_URL + "/tools/.gitignore", $gitIgnorePath);
        SwitchToCRLFLineEndings $gitIgnorePath
        $webClient.DownloadFile($TEMPLATE_URL + "/build.ps1", $thisScriptPath);
        $preSwitchHash = MD5HashFile $thisScriptPath
        SwitchToCRLFLineEndings $thisScriptPath
        $bashScriptPath = Join-Path $PSScriptRoot "build.sh";
        if (Test-Path $bashScriptPath)
        {
            $webClient.DownloadFile($TEMPLATE_URL + "/build.sh", $bashScriptPath);
            SwitchToCRLFLineEndings $bashScriptPath
        }
        if ($thisScriptHash -ne (MD5HashFile $thisScriptPath) -and $thisScriptHash -ne $preSwitchHash)
        {
            Write-Host "The build script has updated please run again."
            exit 2
        }
    }
    catch
    {
        Write-Error "Could not download bootstrap files."
        throw $_.Exception;
    }
}

# Try download NuGet.exe if not exists
if (!(Test-Path $NUGET_EXE)) {
    Write-Host "Downloading NuGet.CommandLine.$NUGET_VERSION package to get NuGet.exe..."
    Write-Host "Package Source = $NUGET_SOURCE"
    try {
        $nugetPackagePath = Join-Path $TOOLS_DIR ("nuget.commandline." + $NUGET_VERSION + ".zip");
        $nugetPackageUrl = $NUGET_SOURCE + "/package/NuGet.CommandLine/" + $NUGET_VERSION;
        (New-Object System.Net.WebClient).DownloadFile($nugetPackageUrl, $nugetPackagePath);

        # Attempt to load compression DLL from .NET 4.5
        $CanLoadCompression = $false;
        try {
            Add-Type -AssemblyName "System.IO.Compression.Filesystem, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089";
            $CanLoadCompression = $true;
        }
        catch { }

        # If we could load the compression DLL use that
        if ($CanLoadCompression)
        {
            Write-Verbose "Decompressing NuGet package with .NET...";
            $zipArchive = [IO.Compression.Zipfile]::OpenRead($nugetPackagePath);
            try 
            {
                $zipEntry = $zipArchive.Entries | Where-Object {$_.FullName -eq "tools/nuget.exe"} | Select-Object -First 1
                [IO.Compression.ZipFileExtensions]::ExtractToFile($zipEntry,$NUGET_EXE);
            }
            finally {
                $zipArchive.Dispose();
            }
        }
        elseif (Test-Path $UNZIP_EXE)
        {
            Write-Verbose "Decompressing NuGet package with unzip.exe...";
            Invoke-Expression "& $UNZIP_EXE -j -C -q `"$nugetPackagePath`" `"tools/nuget.exe`" -d `"$TOOLS_DIR`""
        }
        else {
            Write-Host "NOTE: CLRVersion=$($PSVersionTable.CLRVersion)";
            Write-Error "No available way to unzip package.  Either add unzip.exe to tools/win32 folder or run Powershell under CLR v4 with .NET 4.5.";
            exit 1
        }
        Remove-item $nugetPackagePath
    } catch {
        Write-Error "Could not download Nuget.CommandLine package and extract NuGet.exe."
        exit 1
    }
}

# Save nuget.exe path to environment to be available to child processes
$ENV:NUGET_EXE = $NUGET_EXE

# Restore tools from NuGet?
if(-Not $SkipToolPackageRestore.IsPresent) {
    Push-Location
    Set-Location $TOOLS_DIR

    # Check for changes in packages.config and remove installed tools if true.
    [string] $md5Hash = MD5HashFile($PACKAGES_CONFIG)
    if((!(Test-Path $PACKAGES_CONFIG_MD5)) -Or
      ($md5Hash -ne (Get-Content $PACKAGES_CONFIG_MD5 ))) {
        Write-Verbose -Message "Missing or changed package.config hash..."
        Get-ChildItem -Exclude .gitignore,packages.config,nuget.exe,unzip.exe,Cake.Bakery |
        Remove-Item -Recurse
    }

    Write-Verbose -Message "Restoring tools from NuGet..."
    $NuGetOutput = Invoke-Expression "&`"$NUGET_EXE`" install -ExcludeVersion -OutputDirectory `"$TOOLS_DIR`""

    if ($LASTEXITCODE -ne 0) {
        Throw "An error occurred while restoring NuGet tools."
    }
    else
    {
        $md5Hash | Out-File $PACKAGES_CONFIG_MD5 -Encoding "ASCII"
    }
    Write-Verbose -Message ($NuGetOutput | out-string)
    Pop-Location
}

# Restore addins from NuGet
if (Test-Path $ADDINS_PACKAGES_CONFIG) {
    Push-Location
    Set-Location $ADDINS_DIR

    Write-Verbose -Message "Restoring addins from NuGet..."
    $NuGetOutput = Invoke-Expression "&`"$NUGET_EXE`" install -ExcludeVersion -OutputDirectory `"$ADDINS_DIR`""

    if ($LASTEXITCODE -ne 0) {
        Throw "An error occurred while restoring NuGet addins."
    }

    Write-Verbose -Message ($NuGetOutput | out-string)

    Pop-Location
}

# Restore modules from NuGet
if (Test-Path $MODULES_PACKAGES_CONFIG) {
    Push-Location
    Set-Location $MODULES_DIR

    Write-Verbose -Message "Restoring modules from NuGet..."
    $NuGetOutput = Invoke-Expression "&`"$NUGET_EXE`" install -ExcludeVersion -OutputDirectory `"$MODULES_DIR`""

    if ($LASTEXITCODE -ne 0) {
        Throw "An error occurred while restoring NuGet modules."
    }

    Write-Verbose -Message ($NuGetOutput | out-string)

    Pop-Location
}

# Make sure that Cake has been installed.
if (!(Test-Path $CAKE_EXE)) {
    Throw "Could not find Cake.exe at $CAKE_EXE"
}

# By default use the same package source for Roslyn as we used to bootstrap NuGet
if ($env:CAKE_NUGET_SOURCE -eq $null) {
    $env:CAKE_NUGET_SOURCE = $env:NUGET_SOURCE
}

# Build Cake arguments
$cakeArguments = @("$Script");
if ($Target) { $cakeArguments += "-target=$Target" }
if ($Configuration) { $cakeArguments += "-configuration=$Configuration" }
if ($Verbosity) { $cakeArguments += "-verbosity=$Verbosity" }
if ($ShowDescription) { $cakeArguments += "-showdescription" }
if ($DryRun) { $cakeArguments += "-dryrun" }
if ($Experimental) { $cakeArguments += "-experimental" }
if ($Mono) { $cakeArguments += "-mono" }
$cakeArguments += $ScriptArgs

# Start Cake
Write-Host "Running build script..."
&$CAKE_EXE $cakeArguments
exit $LASTEXITCODE