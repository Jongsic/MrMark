; MrMark per-user installer (Inno Setup 6).
; Compile after build.cmd:  ISCC installer.iss  [/DAppVersion=1.0.0]
; Installs to %LOCALAPPDATA%\Programs\MrMark (no admin), adds a Start Menu
; entry, registers the .md file association, and shows up in Settings > Apps
; with a real uninstaller. The release workflow ships the result as
; MrMark-Setup-<version>.exe.

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

[Setup]
AppId={{9C3B5E64-2A47-4D2E-9F6B-1B8C1D4E7A21}
AppName=MrMark
AppVersion={#AppVersion}
AppPublisher=Jongsic
AppPublisherURL=https://github.com/Jongsic/MrMark
AppSupportURL=https://github.com/Jongsic/MrMark/issues
DefaultDirName={autopf}\MrMark
PrivilegesRequired=lowest
; MIT license shown up front; its as-is / no-liability terms must be
; accepted before installing. Also installed next to the app.
LicenseFile=..\LICENSE
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\MrMark.exe
OutputDir=bin
OutputBaseFilename=MrMark-Setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern

[Files]
Source: "bin\MrMark.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\LICENSE"; DestDir: "{app}"; DestName: "LICENSE.txt"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\MrMark"; Filename: "{app}\MrMark.exe"

[Registry]
; The .md association: MrMark appears in "Open with"; Windows asks the user
; to confirm making it the default (Settings > Default apps, or Open with >
; Always). Everything is removed on uninstall.
Root: HKA; Subkey: "Software\Classes\MrMark.md"; ValueType: string; ValueData: "Markdown Document"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\MrMark.md\DefaultIcon"; ValueType: string; ValueData: """{app}\MrMark.exe"",1"
Root: HKA; Subkey: "Software\Classes\MrMark.md\shell\open\command"; ValueType: string; ValueData: """{app}\MrMark.exe"" ""%1"""
Root: HKA; Subkey: "Software\Classes\.md\OpenWithProgids"; ValueName: "MrMark.md"; ValueType: none; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.markdown\OpenWithProgids"; ValueName: "MrMark.md"; ValueType: none; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.mdown\OpenWithProgids"; ValueName: "MrMark.md"; ValueType: none; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.mkd\OpenWithProgids"; ValueName: "MrMark.md"; ValueType: none; Flags: uninsdeletevalue
; App settings (window placement, recents, one-time flags): not created by
; the installer, but cleaned up on uninstall.
Root: HKA; Subkey: "Software\MrMark"; ValueType: none; Flags: dontcreatekey uninsdeletekey

[Run]
Filename: "{app}\MrMark.exe"; Description: "Launch MrMark"; Flags: nowait postinstall skipifsilent
