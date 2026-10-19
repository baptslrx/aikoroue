; Installateur Windows d'AikoRoue (Inno Setup 6)
#define AppVersion GetEnv("AIKOROUE_VERSION")
#if AppVersion == ""
  #define AppVersion "1.0.0"
#endif

[Setup]
AppId={{9D9CE15D-E046-4B1B-B2F4-411EA4643398}
AppName=AikoRoue
AppVersion={#AppVersion}
AppPublisher=Aikographic
DefaultDirName={localappdata}\Programs\AikoRoue
DefaultGroupName=AikoRoue
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=..\dist
OutputBaseFilename=AikoRoue-Windows-Setup
SetupIconFile=..\assets\icon.ico
UninstallDisplayIcon={app}\AikoRoue.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes

[Languages]
Name: "french"; MessagesFile: "compiler:Languages\French.isl"

[Tasks]
Name: "startup"; Description: "Lancer AikoRoue au démarrage de Windows"; GroupDescription: "Options :"
Name: "desktopicon"; Description: "Créer une icône sur le Bureau"; GroupDescription: "Options :"; Flags: unchecked

[Files]
Source: "..\desktop\dist\AikoRoue\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\AikoRoue"; Filename: "{app}\AikoRoue.exe"
Name: "{group}\Désinstaller AikoRoue"; Filename: "{uninstallexe}"
Name: "{userdesktop}\AikoRoue"; Filename: "{app}\AikoRoue.exe"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "AikoRoue"; ValueData: """{app}\AikoRoue.exe"""; Tasks: startup; Flags: uninsdeletevalue

[Run]
Filename: "{app}\AikoRoue.exe"; Description: "Lancer AikoRoue"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "taskkill"; Parameters: "/F /IM AikoRoue.exe"; Flags: runhidden; RunOnceId: "KillAikoRoue"
