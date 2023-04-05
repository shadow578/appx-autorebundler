# AppX Re-Bundler

a tool to re-bundle an appx package into a new one, with (optional) modifications to the app

## What is this?

This tool is a re-bundler for appx packages. It takes an appx package, and re-bundles it into a new one, with (optional) modifications to the app (or appx manifest).
it works by extracting the appx package, allowing you to modify the app, and then re-bundling and signing it with a new certificate.

## Why would I want to do this?

the microsoft store has no way to disable auto-updates for specific apps, meaning that if you want to stay on a older version of an app, you cannot.
this tool allows you to re-bundle an appx package, effectively changing the identity of the app, and thus allowing you to disable auto-updates for that app. Microsoft store will not update the app, as it will think it is a different app.

## How do I use it?

1. clone this repo (either with `git clone`, or by downloading the zip file from github)
2. install `MakeAppX.exe` and `SignTool.exe` (see [below](#makeappxexe-and-signtoolexe))
3. (optionally) modify the `rebundler.ps1` script to automatically run actions for all packages in the bundle (see [below](#automatic-patching))
4. open a powershell propmt in the directory you cloned this repo to and run the rebundler script. (see [below](#command-line-usage) for more details)
   - if you get an error stating that you cannot run scripts, run `Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process` and then try again.
   - if you get other errors, you may have to install powershell core 7.3. you can download it from [here](https://learn.microsoft.com/de-de/powershell/scripting/install/installing-powershell-on-windows?view=powershell-7.3). I've only tested this script with powershell core 7.3.3.

### `MakeAppX.exe` and `SignTool.exe`

these tools are part of the [Windows SDK](https://developer.microsoft.com/en-us/windows/downloads/windows-10-sdk).
if installed, you should be able to find them in `C:\Program Files (x86)\Windows Kits\10\bin\<version number, eg. 10.0.19041.0>\x64\`.
if you can't find them, you can download the SDK from the link above.

you will need to add the directory containing these tools to your `PATH` environment variable.
example to do this temporarily (in powershell):

```powershell
$env:PATH += ';C:\Program Files (x86)\Windows Kits\10\bin\10.0.19041.0\x64\'
```

you can test if the tools are on your path by running `MakeAppX.exe` and `SignTool.exe` in a command prompt.
If you get an error saying the command is not found, they are not yet on your path.

alternatively, you can provide the absolute paths to those tools via the `-MakeAppX` and `-SignTool` parameters.
Example:

```powershell
.\rebundler.ps1 -MakeAppX 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.19041.0\x64\MakeAppX.exe' -SignTool 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.19041.0\x64\SignTool.exe' <... the rest of the command ...>
```

### Automatic Patching

the script includes a function that is called once the bundle is fully unpacked (at the end of the `-UnPack` action). it allows you to automatically apply patches to modify all (or just some) of the unpacked apps in the bundle.
By default, the function contains some example code that will remove the app signature file `AppXSignature.p7x`, the `AppXBlockMap.xml` and `CodeIntegrity.cat` files from all unpacked apps.
it also includes a dummy implementation for automatically patching the appx manifest in order to disable auto-updates for the app.
Since i'm not sure if the original publishers of the app i've developed this for would be happy with me releasing their name, i've replaced them with dummy values.

The function itself is called `Invoke-UserScript` and is located around the middle of the script (great placement, i know :P).
It is provided with two parameters: `$ExtractedBundleDir` and `$ExtractedPackDirs`.
`$ExtractedBundleDir` is the path to the directory where the bundle (.appxpackage or .msixpackage) was extracted to.
`$ExtractedPackDirs` is an array of paths to the directories where the individual packages (.appx or .msix) were extracted to.

```powershell
function Invoke-UserScript([string] $ExtractedBundleDir, [string[]] $ExtractedPackDirs) {
    Write-information "Running user script"
    # ... your code here ...
}
```

#### How to use automatic manifest patching

the code for patching the appx manifest is present, but effectively disabled by default.
to enable it, you have to update the `Update-AppXManifest` function.
The function is called once for each appx manifest in the bundle, and is provided with the contents of the manifest as a string.
Whatever is returned from the function is written to the manifest file, overwriting the original file.

Example for disabling auto-updates for a fictional app 'SketchPad PDF' by a fictional publisher called 'SketchPad':

```powershell
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
```

### Command Line Usage

the command line options of are the following:

| Option          | Mandatory | Description                                                                                                                                                                                           |
| --------------- | --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `-TargetBundle` | YES       | the path to the bundle to be patched. supports both `.appxpackage` and `.msixpackage` files.                                                                                                          |
| `-PFXPass`      | YES       | the password for the pfx file that will be used to sign the patched bundle. Set this to a semi-random string (not empty!)                                                                             |
| `-WorkDir`      | NO        | working directory. defaults to `.\work`, which should work fine in most cases.                                                                                                                        |
| `-MakeAppX`     | NO        | path to the `MakeAppX.exe` tool. if not provided, the script will try to find it in the path.                                                                                                         |
| `-SignTool`     | NO        | path to the `SignTool.exe` tool. if not provided, the script will try to find it in the path.                                                                                                         |
| `-UnPack`       | KINDA     | Un-Packs the bundle to the working directory. if the same bundle was previously unpacked, you'll be prompted to delte it first. This stage also runs the `Invoke-UserScript` function.                |
| `-RePack`       | KINDA     | Re-Packs the bundle from the working directory and signs it. You have to run the `-CreateCert` once before running this.                                                                              |
| `-CreateCert`   | KINDA     | Creates a new self-signed certificate that will be used to sign the patched bundle. This also deploys the certificate as a trusted root CA. The certificate will be written to the current directory. |

On every run of the script, both the `-TargetBundle` and `-PFXPass` parameters have to be provided.
when no action is specified, the script will just do nothing.

### Example usage:

in this example, a bundle for the world-famous app `SketchPad PDF` is patched and re-bundled.

The following assumptions are made:

- the bundle is located in the current directory and is called `SketchPadPDF.appxpackage`
- both `MakeAppX.exe` and `SignTool.exe` are on the path
- automatic manifest patching was set-up beforehand

#### Auto-Patching, all it in one go:

```powershell
.\rebundler.ps1 -TargetBundle .\SketchPadPDF.appxpackage -PFXPass 'MyAwesomePassword' -CreateCert -UnPack -RePack
```

This will create a new self-signed certificate, unpack the bundle, apply the automatic patches, re-pack the bundle and sign it.
you'll have no way to do manual adjustments, it all happens automatically.

#### Manual Patching

1. create a new self-signed certificate:

```powershell
.\rebundler.ps1 -TargetBundle .\SketchPadPDF.appxpackage -PFXPass 'MyAwesomePassword' -CreateCert
```

this creates and installs a new self-signed certificate that will be used to sign the patched bundle later on.

2. unpack the bundle:

```powershell
.\rebundler.ps1 -TargetBundle .\SketchPadPDF.appxpackage -PFXPass 'MyAwesomePassword' -UnPack
```

this will unpack the bundle to `.\work\SketchPadPDF`.
Automatic patching has already been applied at this point, but you now have the opportunity to do manual adjustments.

3. re-pack the bundle:

```powershell
.\rebundler.ps1 -TargetBundle .\SketchPadPDF.appxpackage -PFXPass 'MyAwesomePassword' -RePack
```

this will re-pack the bundle in `.\work\SketchPadPDF` and sign it with the certificate that was created in step 1.
the resulting bundle will be written to `.\repacked_SketchPadPDF.appxpackage` and should be ready to be installed.

# Notice

this script is provided as-is, without any warranty. use at your own risk.
additionally, this script is provided for educational purposes only. it is not intended to be used for malicious purposes. if you do use it for malicious purposes, you are solely responsible for your actions. i am not responsible for any damage caused by this script. you have been warned.
