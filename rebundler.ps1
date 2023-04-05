#
# a tool to complete unpack, modify, repack, and then sign a appx/msixbundle
#
param(
    # input
    [Parameter(Mandatory = $true)] [string] $TargetBundle,
    [Parameter(Mandatory = $true)] [string] $PFXPass,

    # environment
    [string] $WorkDir = "$PSScriptRoot\work",
    [string] $MakeAppX = "makeappx.exe",
    [string] $SignTool = "signtool.exe",

    # actions
    [switch] $UnPack,
    [switch] $RePack,
    [switch] $CreateCert
)

$PackExtensions = @("msix", "appx")

#
# Utils
#
function Get-FileName([string] $Path, [switch] $WithoutExtension) {
    if ($WithoutExtension) {
        return [System.IO.Path]::GetFileNameWithoutExtension($Path)
    }
    else {
        return [System.IO.Path]::GetFileName($Path)
    }
}

function Join-Path([string] $Path1, [string] $Path2) {
    return [System.IO.Path]::Combine($Path1, $Path2)
}


#
# MakeAppX wrapper
#
function Invoke-UnBundle([string] $BundleFile, [string] $TargetDir) {
    Write-Information "UN-bundling bundle $BundleFile to $TargetDir"
    & $MakeAppX unbundle /p $BundleFile /d $TargetDir /v

    if ($LastExitCode -ne 0) {
        throw "Failed to unbundle $BundleFile"
    }
}

function Invoke-UnPack([string] $PackFile, [string] $TargetDir) {
    Write-Information "UN-packing pack $PackFile to $TargetDir"
    & $MakeAppX unpack /p $PackFile /d $TargetDir /v

    if ($LastExitCode -ne 0) {
        throw "Failed to unpack $PackFile"
    }
}

function Invoke-Bundle([string] $TargetDir, [string] $BundleFile) {
    Write-Information "Bundling $TargetDir to $BundleFile"
    & $MakeAppX bundle /d $TargetDir /p $BundleFile /v

    if ($LastExitCode -ne 0) {
        throw "Failed to bundle $BundleFile"
    }

    # sign
    Invoke-SignTool -FileToSign $BundleFile -PFXFile $global:PFXFile -PFXPass $PFXPass -HashAlgo "SHA256"
}

function Invoke-Pack([string] $TargetDir, [string] $PackFile) {
    Write-Information "Packing $TargetDir to $PackFile"
    & $MakeAppX pack /h SHA256 /d $TargetDir /p $PackFile /v

    if ($LastExitCode -ne 0) {
        throw "Failed to pack $PackFile"
    }

    # sign
    Invoke-SignTool -FileToSign $PackFile -PFXFile $global:PFXFile -PFXPass $PFXPass -HashAlgo "SHA256"
}

#
# SignTool wrapper
#
function Invoke-SignTool([string] $FileToSign, [string] $PFXFile, [string] $PFXPass, [string] $HashAlgo) {
    Write-Information "Signing $FileToSign with $PFXFile using $HashAlgo"
    if (-not (Test-Path $PFXFile)) {
        throw "Certificate file $PFXFile does not exist"
    }

    & $SignTool sign /f $PFXFile /p "$PFXPass" /fd $HashAlgo /tr "http://timestamp.digicert.com" /td SHA256 $FileToSign

    if ($LastExitCode -ne 0) {
        throw "Failed to sign $FileToSign"
    }
}

#
# Certificate Helpers
#
function Get-DummySubject() {
    return "CN=AUTOBUNDLER, DC=$($env:COMPUTERNAME -replace "\W")"
}

function New-CodeSigningCertificate([string] $Subject, [string] $PFXPass, [string] $PFXFile, [string] $CRTFile) {
    # create certificate
    $cert = New-SelfSignedCertificate -Type CodeSigningCert -KeyUsage DigitalSignature -Subject "$Subject" -CertStoreLocation "cert:\CurrentUser\My" 
    
    # create export dir if needed
    $CRTDir = [System.IO.Path]::GetDirectoryName($CRTFile)
    if (-not (Test-Path $CRTDir)) {
        New-Item -ItemType Directory -Path $CRTDir -Force | Out-Null
    }

    # export to pfx and crt
    $cert | Export-PfxCertificate -FilePath $PFXFile -Password (ConvertTo-SecureString -String "$PFXPass" -Force -AsPlainText) | Out-Null
    $cert | Export-Certificate -FilePath $CRTFile -Type CERT | Out-Null

    # remove from store
    Remove-Item -Path "Cert:\CurrentUser\My\$($cert.Thumbprint)" -Force
}

function Install-RootCA([string] $CRTFile) {
    Start-Process -FilePath "powershell.exe" -ArgumentList "Import-Certificate -FilePath $CRTFile -CertStoreLocation Cert:\LocalMachine\Root" -Verb RunAs -Wait
}

#
# User-Defined script to run on unbundled files
#
function Invoke-UserScript([string] $ExtractedBundleDir, [string[]] $ExtractedPackDirs) {
    Write-information "Running user script"

    # remove p7x signatures
    $ExtractedBundleDir | ForEach-Object {
        Get-ChildItem -Path $_ -Filter "*.p7x" -Recurse | ForEach-Object { 
            Write-information "removing signature $($_.FullName)"
            Remove-Item -Path $_ -Force
        }
    }

    # remove AppxBlockMap.xml
    $ExtractedBundleDir | ForEach-Object {
        Get-ChildItem -Path $_ -Filter "AppxBlockMap.xml" -Recurse | ForEach-Object { 
            Write-information "removing AppxBlockMap.xml $($_.FullName)"
            Remove-Item -Path $_ -Force
        }
    }

    # remove CodeIntegrity.cat
    $ExtractedBundleDir | ForEach-Object {
        Get-ChildItem -Path $_ -Filter "CodeIntegrity.cat" -Recurse | ForEach-Object { 
            Write-information "removing CodeIntegrity.cat $($_.FullName)"
            Remove-Item -Path $_ -Force
        }
    }

    # replace identity string in all AppxManifest.xml and Appxbundlemanifest.xml files
    # see https://learn.microsoft.com/en-us/windows/msix/package/unsigned-package
    function Update-AppXManifest([Parameter(ValueFromPipeline = $true)][string] $ManifestContents) {
        # to disable auto updates, we have to decouple the app from the original one. this is easiest done by changing the app identity.
        # as such, all of the following steps target the app identity node of the manifest:
        # Example Node: <Identity Name="SketchPad.SketchPadPDF" Publisher="CN=SketchPad" Version="1.0.0" ProcessorArchitecture="x86" />
        #
        # (you'll be able to find this node in any appx manifest)
    
        # first, we target the app id, by replacing the 'Name' attribute of teh 'Identity' node
        # in this case, 'SketchPad.SketchPadPDF' is replaced with 'NOTSketchPad.SketchPadPDF'
        $ManifestContents = $ManifestContents -replace "Name=`"SketchPad.SketchPadPDF`"", "Name=`"NOTSketchPad.SketchPadPDF`""
    
        # publisher
        # second, we target the publisher id, by replacing the 'Publisher' attribute of the 'Identity' node
        # in this case, 'CN=SketchPad' is replaced with a dummy value generated by the 'Get-DummySubject' function
        # Note 1: you should stick to the 'Get-DummySubject' function, as this value has to match the subject of the certificate that is later used to sign the app
        # Note 2: theoretically, you could skip this step and keep the original publisher id, but that could lead to issues in the future
        $ManifestContents = $ManifestContents -replace "Publisher=`"CN=SketchPad`"", "Publisher=`"$(Get-DummySubject)`""
        return $ManifestContents
    }
    $ExtractedBundleDir | ForEach-Object {
        Get-ChildItem -Path $_ -Filter "*.xml" -Recurse 
        | Where-Object { ((Get-FileName $_.FullName) -eq "AppxManifest.xml") -or ((Get-FileName $_.FullName) -eq "AppxBundleManifest.xml") } 
        | ForEach-Object { 
            Write-information "updating manifest $($_.FullName)"
            (Get-Content -Path $_.FullName -Raw) | Update-AppXManifest | Out-File -FilePath $_.FullName -Encoding UTF8
        }
    }
}

#
# un- and re-bundle functions
#
function UnBundle([string] $UnBundledDir, [string] $PersistFile) {
    # delete unbundle dir if it exists, with user confirmation
    if (Test-Path $UnBundledDir) {
        $Confirmation = Read-Host "Unbundle $UnBundledDir already exists. Delete it? (y/n)"
        if ($Confirmation -eq "y") {
            Remove-Item -Path $UnBundledDir -Recurse -Force
        }
        else {
            Write-Information "Aborting"
            return
        }
    }

    # unbundle the bundle to the work dir
    Invoke-UnBundle -BundleFile $TargetBundle -TargetDir $UnBundledDir

    # get all packs contained in the bundle
    $PackFiles = @()
    foreach ($PackExtension in $PackExtensions) {
        $PackFiles += Get-ChildItem -Path $UnBundledDir -Filter "*.$PackExtension"
    }

    # unpack all packs contained in the bundle and delete the packs
    $UnPackedDirs += @()
    foreach ($PackFile in $PackFiles) {
        $UnPackedDir = Join-Path $UnBundledDir (Get-FileName $PackFile -WithoutExtension)
        $UnPackedDirs += $UnPackedDir
        Invoke-UnPack -PackFile $PackFile -TargetDir $UnPackedDir
        Remove-Item -Path $PackFile -Force
    }

    # write persist file
    $PackFiles | ForEach-Object { $_.FullName } | ConvertTo-Json | Out-File -FilePath $PersistFile -Encoding UTF8

    # run user script
    Invoke-UserScript -ExtractedBundleDir $UnBundledDir -ExtractedPackDirs $UnPackedDirs
}

function ReBundle([string] $UnBundledDir, [string] $PersistFile) {
    # read persist file
    $PackFiles = Get-Content -Path $PersistFile -Raw | ConvertFrom-Json

    # copy unbundled dir for re-packing
    $RePackDir = Join-Path $WorkDir "repack"
    Write-Information "Copying $UnBundledDir to $RePackDir for re-packing"
    Remove-Item -Path $RePackDir -Recurse -Force -ErrorAction "SilentlyContinue"
    Copy-Item -Path $UnBundledDir -Destination $RePackDir -Recurse -Force
    
    # re-pack all packs, deleting (copied) unpacked dirs
    foreach ($PackFile in $PackFiles) {
        $UnPackedDir = Join-Path $RePackDir (Get-FileName $PackFile -WithoutExtension)
        $TargetPackFile = Join-Path $RePackDir (Get-FileName $PackFile)
        Invoke-Pack -TargetDir $UnPackedDir -PackFile $TargetPackFile
        Remove-Item -Path $UnPackedDir -Recurse -Force
    }
    
    # re-bundle the bundle
    $TargetBundleFile = Join-Path $PSScriptRoot "repack_$(Get-FileName $TargetBundle)"
    Remove-Item -Path $TargetBundleFile -Force -ErrorAction "SilentlyContinue"
    Invoke-Bundle -TargetDir $RePackDir -BundleFile $TargetBundleFile
}

#
# Main
#
function Main() {
    # determine paths
    $UnBundledDir = Join-Path $WorkDir (Get-FileName $TargetBundle -WithoutExtension)
    $PersistFile = Join-Path $WorkDir "$(Get-FileName $TargetBundle -WithoutExtension)_persist.json"
    $global:PFXFile = Join-Path $PSScriptRoot "selfsign.pfx"
    $CRTFile = Join-Path $PSScriptRoot "selfsign.cer"

    while ($CreateCert) {
        # check if cert already exists
        if (Test-Path $PFXFile) {
            $Confirmation = Read-Host "Cert $PFXFile already exists. Delete it? (y/n)"
            if ($Confirmation -eq "y") {
                Remove-Item -Path $PFXFile -Force -ErrorAction "SilentlyContinue"
                Remove-Item -Path $CRTFile -Force -ErrorAction "SilentlyContinue"
                Write-Host "certificate files were deleted. Please remove the certificate from the trusted root ca store manually." -ForegroundColor Red
            }
            else {
                Write-Information "Aborting"
                break
            }
        }

        # create cert and install as trusted root ca
        New-CodeSigningCertificate -Subject (Get-DummySubject) -PFXPass $PFXPass -PFXFile $PFXFile -CRTFile $CRTFile
        Install-RootCA -CRTFile $CRTFile
        break
    }

    if ($UnPack) {
        UnBundle -UnBundledDir $UnBundledDir -PersistFile $PersistFile
    }

    if ($RePack) {
        ReBundle -UnBundledDir $UnBundledDir -PersistFile $PersistFile
    }
}
$DebugPreference = "Continue"
$InformationPreference = "Continue"
$ErrorActionPreference = "Stop"
Main
