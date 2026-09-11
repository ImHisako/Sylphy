#ifndef AppVersion
  #error AppVersion must be supplied by the release workflow
#endif
#ifndef BuildNumber
  #error BuildNumber must be supplied by the release workflow
#endif
[Setup]
AppId={{68701314-551F-4B7D-A4F7-DA8D803DB5EE}
AppMutex=Local\Sylphy-68701314-551F-4B7D-A4F7-DA8D803DB5EE
AppName=Sylphy
AppVersion={#AppVersion}
VersionInfoVersion={#AppVersion}.{#BuildNumber}
AppPublisher=Sylphy
AppPublisherURL=https://github.com/ImHisako/Sylphy
DefaultDirName={localappdata}\Programs\Sylphy
DefaultGroupName=Sylphy
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UsePreviousAppDir=yes
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\sylphy.exe
OutputDir=..\release-assets
OutputBaseFilename=sylphy-v{#AppVersion}-windows-x64-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
SetupLogging=yes

[Languages]
Name: "italian"; MessagesFile: "compiler:Languages\Italian.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Sylphy"; Filename: "{app}\sylphy.exe"

[Run]
Filename: "{app}\sylphy.exe"; Description: "Avvia Sylphy"; Flags: nowait postinstall skipifsilent
