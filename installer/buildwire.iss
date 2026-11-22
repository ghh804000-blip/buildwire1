; BuildWire installer (Inno Setup 6).
;
; Build the app first:   flutter build windows --release
; Then compile:          ISCC installer\buildwire.iss
; Output:                dist\buildwire-setup.exe
;
; Installs per user (no administrator prompt) into %LOCALAPPDATA%\Programs\BuildWire, with Start menu and optional
; desktop shortcuts and an entry in Settings > Apps for uninstalling. Uninstalling offers to delete the settings and the AI key
; kept in %APPDATA%\BuildWire (default: keep them). The Visual C++ runtime DLLs ship next to the exe,
; so nothing else needs to be installed on the target PC.

#define AppName "BuildWire"
#define AppVersion "1.3.0"
#define AppExe "BuildWire.exe"
#define Release "..\build\windows\x64\runner\Release"

[Setup]
; Keep this id the same in every version so updates replace the old install.
AppId={{A89FBB1C-DFE5-4666-8FE0-641A5B5388BF}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppName}
VersionInfoVersion={#AppVersion}
VersionInfoProductName={#AppName}
VersionInfoDescription={#AppName} Setup
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir=..\dist
OutputBaseFilename=buildwire-setup
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
#ifexist AddBackslash(CompilerPath) + "Languages\Indonesian.isl"
Name: "indonesian"; MessagesFile: "compiler:Languages\Indonesian.isl"
#endif

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#Release}\{#AppExe}"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Release}\*.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Release}\native_assets.json"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "{#Release}\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[CustomMessages]
RemoveUserData=Hapus juga pengaturan dan API key BuildWire?%n%nIni menghapus API key AI, pilihan model, tema, dan proyek terakhir yang tersimpan otomatis di folder:%n%1%n%nProyek yang sudah kamu simpan sebagai file (.bwproj) tidak ikut terhapus.%n%nPilih "No" untuk menyimpannya, misalnya kalau kamu hanya memasang ulang.

[Code]
// Settings, the encrypted AI key and the autosaved project live in %APPDATA%\BuildWire, outside the install folder,
// so they survive updates. On uninstall the user may remove them too; a silent uninstall always keeps them.
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  DataDir: String;
begin
  if CurUninstallStep <> usPostUninstall then
    Exit;
  DataDir := ExpandConstant('{userappdata}\{#AppName}');
  if UninstallSilent or not DirExists(DataDir) then
    Exit;
  if MsgBox(FmtMessage(CustomMessage('RemoveUserData'), [DataDir]), mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
    DelTree(DataDir, True, True, True);
end;
