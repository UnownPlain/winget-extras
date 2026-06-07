# WinGet Extras

A WinGet source for extra packages, especially ones that can't be added to [microsoft/winget-pkgs](https://github.com/microsoft/winget-pkgs). They might:

* [Use interactive-only installers](https://github.com/microsoft/winget-pkgs/issues?q=label%3AInteractive-Only-Installer)
* [Need third-party download links](https://github.com/microsoft/winget-pkgs/issues?q=label%3AInteractive-Only-Download)
* [Trigger false-positive malware detections](https://github.com/microsoft/winget-pkgs/issues?q=label%3ABinary-Validation-Error)
* [Require specific hardware to test](https://github.com/microsoft/winget-pkgs/issues?q=label%3A%22Hardware%22)
* Or otherwise be easier to add here, than upstream

Packages are provided on a best-effort basis and may not be up-to-date. If you find a problem or want to add an app, [open an issue](https://github.com/pl4nty/winget-extras/issues/new/choose).

This repo was inspired by [ScoopInstaller/Extras](https://github.com/ScoopInstaller/Extras). Want to host your own custom source? Check out [pl4nty/winget-pkgs-selfhost](https://github.com/pl4nty/winget-pkgs-selfhost).

## Quickstart

At the moment, you'll need to trust this [self-signed certificate](https://github.com/pl4nty/winget-extras/blob/main/index/cert.cer) at the machine level.

> [!CAUTION]
> This has significant security concerns, so I'm not providing instructions. But it won't be necessary soon once I have access to a publicly-trusted certificate.

Then with admin privileges, run:

```sh
winget source add --name extras --type Microsoft.PreIndexed.Package --arg https://winget.tplant.com.au/cache
```

Extra packages will be available with commands like `winget search` or `winget install`.

## Validation

Packages are validated automatically using [GitHub Actions](https://github.com/pl4nty/winget-extras/blob/main/.github/workflows/validate.yml), or manually using `SandboxTest` from `winget-pkgs`. There are some limitations:

* Interactive installation is only tested if silent installation fails
* The `arm` architecture (32-bit ARM) is not tested

Try validation yourself with these commands.

```sh
git clone https://github.com/microsoft/winget-pkgs
cd winget-pkgs\Tools
.\SandboxTest.ps1 -Manifest ..\..\winget-extras\manifests\m\Microsoft\AzIPLogViewer\1.0\
```
