; Cartunez POS Windows installer (Inno Setup 6).
; Build with windows\installer\build.ps1, which supplies AppVersion, SourceDir and CrtDir.

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif

[Setup]
; Keep this AppId forever: it is how Windows recognises upgrades of the same app.
AppId={{7EDBDD11-D029-4F8B-B3A6-6C8B65375F40}
AppName=Cartunez POS
AppVersion={#AppVersion}
AppVerName=Cartunez POS {#AppVersion}
AppPublisher=Cartunez
AppPublisherURL=https://pos.cartunez.in
DefaultDirName={autopf}\Cartunez POS
DefaultGroupName=Cartunez POS
DisableProgramGroupPage=yes
; Installs for the current user without an admin prompt; an admin can choose "all users".
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
OutputDir=..\..\build\installer
OutputBaseFilename=CartunezPOS-Setup-{#AppVersion}
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\cartunez_pos.exe
UninstallDisplayName=Cartunez POS
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
#ifdef CrtDir
; Visual C++ runtime next to the exe, so the app starts on a fresh Windows install.
Source: "{#CrtDir}\msvcp140.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#CrtDir}\vcruntime140.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#CrtDir}\vcruntime140_1.dll"; DestDir: "{app}"; Flags: ignoreversion
#endif

[Icons]
Name: "{group}\Cartunez POS"; Filename: "{app}\cartunez_pos.exe"
Name: "{group}\Uninstall Cartunez POS"; Filename: "{uninstallexe}"
Name: "{autodesktop}\Cartunez POS"; Filename: "{app}\cartunez_pos.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\cartunez_pos.exe"; Description: "{cm:LaunchProgram,Cartunez POS}"; Flags: nowait postinstall skipifsilent

; The register's saved sales and sign-in live in %APPDATA%\in.cartunez\Cartunez POS.
; Uninstalling deliberately leaves them, so unsent sales are never lost.
