param 
( 
  [parameter(Mandatory = $true)]
	[string]
	$project,
	[parameter(Mandatory = $false)]
	[string]
	$configFile
)

$opsProjects = @{}
$omsProjects = @{}
$clientProjects = @{}
$rbrProjects = @{}

function ExtractPackage($package,$path){
    import-module Pscx
    if(-not (Test-Path "$path")){ 
        New-Item "$path" -type directory
    }
    expand-archive $package "$path"
}

function ValidateAndLoadWebAdminModule() {
    if ([System.Version] (Get-ItemProperty -path "HKLM:\Software\Microsoft\Windows NT\CurrentVersion").CurrentVersion -ge [System.Version] "6.1") {
        if(-not(Get-Module -ListAvailable | Where-Object { $_.name -eq "WebAdministration" })) {
            Write-Output 'The IIS 7.0 PowerShell Snap-in is required. The Deployment script will now exit' -foregroundcolor red
            Write-Output
            Wait-KeyPress("Press any-key to navigate to IIS 7.0 PowerShell Snap-in download site...")
            [System.Diagnostics.Process]::Start("http://learn.iis.net/page.aspx/429/installing-the-iis-70-powershell-snap-in/")
            Exit
        } else {
            Write-Output "Importing WebAdministration"
            import-module WebAdministration
        }
    } else {
        Add-PSSnapin WebAdministration -erroraction SilentlyContinue
        if((Get-PSSnapin $SNAPIN) -eq $NULL) {
          Write-Output 'The IIS 7.0 PowerShell Snap-in is required. The Deployment script will now exit' -foregroundcolor red
          Write-Output
          Wait-KeyPress("Press any-key to navigate to IIS 7.0 PowerShell Snap-in download site...")
          [System.Diagnostics.Process]::Start("http://learn.iis.net/page.aspx/429/installing-the-iis-70-powershell-snap-in/")
          Exit
        }
    }
}

function CreateApplicationPool($name) {
	$opsAppPool = New-WebAppPool -Name $name -Force
	Set-ItemProperty "IIS:\AppPools\$name" managedRuntimeVersion v4.0
	$opsAppPool.Recycle()
	Write-Host "[Info] Created [$name] IIS Application Pool"
}

function InitProjects(){
  $baseurl = "http://vmteambuildserver";
  $url = "$baseurl/httpAuth/app/rest/projects/id:project2";
  $webclient = new-object system.net.webclient
  $webclient.credentials = new-object system.net.networkcredential("sdeal", "Jannina1111")
  $result = [xml] $webclient.DownloadString($url)
  foreach ($buildType in ($result.project.buildTypes.buildType)){
    $opsProjects[$buildType.name] = $buildType.id
  }
  $url = "$baseurl/httpAuth/app/rest/projects/id:project3";
  $result = [xml] $webclient.DownloadString($url)
  foreach ($buildType in ($result.project.buildTypes.buildType)){
    $omsProjects[$buildType.name] = $buildType.id
  }
  $url = "$baseurl/httpAuth/app/rest/projects/id:project11";
  $result = [xml] $webclient.DownloadString($url)
  foreach ($buildType in ($result.project.buildTypes.buildType)){
    $rbrProjects[$buildType.name] = $buildType.id
  }
 # We killed the client ui app
#  $url = "$baseurl/httpAuth/app/rest/projects/id:project5";
#  $result = [xml] $webclient.DownloadString($url)
#  foreach ($buildType in ($result.project.buildTypes.buildType)){
#    $clientProjects[$buildType.name] = $buildType.id
#  }
}

function Init(){
    InitProjects;
    $hash = @{}
    if(($configFile -eq '') -or (-not (Test-Path ".\$configFile"))){
        $configFile = "local.properties"
        if(-not (Test-Path ".\$configFile")){
           Write-Host "Unable to load any $configFile. Exiting."
           Exit -1;
        }
    }
    Write-Host "Loading $configFile"
    foreach ($line in (Get-Content($configFile))){
      $key,$value = $line.split('=')
      $hash[$key] = $value
    }
    return $hash
}

function getBuildId($configId, $pin_status){
  if($pin_status -eq $true){
    $address = "http://vmteambuildserver/app/rest/buildTypes/id:$configId/builds/status:SUCCESS,pinned:$pin_status/id?guest=1";
  }else{
    $address = "http://vmteambuildserver/app/rest/buildTypes/id:$configId/builds/status:SUCCESS/id?guest=1";
  }
  return (new-object net.webclient).DownloadString($address);
}

function getBuildNum($configId, $pin_status){
  if($pin_status -eq $true){
    $address = "http://vmteambuildserver/app/rest/buildTypes/id:$configId/builds/status:SUCCESS,pinned:$pin_status/number?guest=1";
  }else{
    $address = "http://vmteambuildserver/app/rest/buildTypes/id:$configId/builds/status:SUCCESS/number?guest=1";
  }
  return (new-object net.webclient).DownloadString($address);
}

function getOpsProjectId($str){
  return $opsProjects[$str];
}

function getOmsProjectId($str){
  return $omsProjects[$str];
}

function getClientProjectId($str){
  return $clientProjects[$str];
}

function getRbrProjectId($str){
  return $rbrProjects[$str];
}

function Set-DtsPackageParams {
    param(
        [xml]$XmlConfig = $null,
        $ParamHash = @{}
    );

 
    $ParamHash.Keys | %{
        $PropertyPath =  $_;
        $Value = $ParamHash.$_;
        $configValueNode = $XmlConfig | Select-Xml "//Configuration[@Path=`"$PropertyPath`"]"
        $configValueNode.Node.ConfiguredValue = $Value.ToString()
    }
}

function force-resolve-path($filename)
{
  $filename = Resolve-Path $filename -ErrorAction SilentlyContinue -ErrorVariable _frperror
  if (!$filename)
  {
    return $_frperror[0].TargetObject
  }
  return $filename
}

function Get-ConfigFileName {
	param (
		$FileNamePrefix
	)
	$formattedName = $hash['env.name']
	$newPackageConfigPath = force-resolve-path("$package\..\DtsEnvironmentConfig")
  Write-Host $newPackageConfigPath

	if(-not( Test-Path $newPackageConfigPath)) {
		New-Item $newPackageConfigPath -type directory
	}

	$file = [string]::Format("{0}\{1}-{2}.dtsConfig", $newPackageConfigPath, $FileNamePrefix, $formattedName)
	$file
}

function Get-SqlCmdParams {
    param(
        $ParamHash = @{}
    );
 
    $Params = "";
    $ParamHash.Keys | %{
        $Property =  $_;
        $Value = $ParamHash.$_;
        $Params += " -v $Property=```"$Value```"";
    }
    $Params
}

function RunScript {
    param(
        $SqlFile = '',
        $SqlVariableHash = @{}
    );
    $sqlvariables = Get-SqlCmdParams -ParamHash $SqlVariableHash

    Invoke-Expression "sqlcmd.exe -S $DatabaseServer -d $Database -U $user -P $pass -i $sqlFile $sqlvariables"
}

function Install-ReportBasedRedemption{
    $packagePath = ([IO.Path]::GetFullPath("$package\SSIS\Report Based Redemptions.dtsx"))
    $packageConfigPath = ([IO.Path]::GetFullPath("$package\SSIS\Report Based Redemptions_Config.dtsConfig"))

    $xml = [xml](get-content "$packageConfigPath")

    Set-DtsPackageParams -XmlConfig $xml -ParamHash @{ "\Package.Variables[User::APIEndDateDiff].Properties[Value]" = $hash['User.APIEndDateDiff'];
                                                       "\Package.Variables[User::APIStartDateDiff].Properties[Value]" = $hash['User.APIStartDateDiff'];
                                                       "\Package.Variables[User::DataBaseName].Properties[Value]" = $hash['User.DataBaseName'];
                                                       "\Package.Variables[User::DebugFileLocation].Properties[Value]" = $hash['User.DebugFileLocation'];
                                                       "\Package.Variables[User::DebugMessage].Properties[Value]" = $hash['User.DebugMessage'];
                                                       "\Package.Variables[User::DefaultArchiveLocation].Properties[Value]" = $hash['User.DefaultArchiveLocation'];
                                                       "\Package.Variables[User::FailureNoticeAddress].Properties[Value]" = $hash['User.FailureNoticeAddress'];
                                                       "\Package.Variables[User::MailServer].Properties[Value]" = $hash['User.MailServer'];
                                                       "\Package.Variables[User::OMSCampaignTable].Properties[Value]" = $hash['User.OMSCampaignTable'];
                                                       "\Package.Variables[User::OMSFIOrganization].Properties[Value]" = $hash['User.OMSFIOrganization'];
                                                       "\Package.Variables[User::OMSOfferRedemptionTable].Properties[Value]" = $hash['User.OMSOfferRedemptionTable'];
                                                       "\Package.Variables[User::OMSOfferTable].Properties[Value]" = $hash['User.OMSOfferTable'];
                                                       "\Package.Variables[User::RewardFileFolder].Properties[Value]" = $hash['User.RewardFileFolder'];
                                                       "\Package.Variables[User::SeverName].Properties[Value]" = $hash['User.ServerName'];
                                                       "\Package.Variables[User::SupportOMS322].Properties[Value]" = $hash['User.SupportOMS322'];
                                                       "\Package.Variables[User::WorkingFolder].Properties[Value]" = $hash['User.WorkingFolder'];
                                                     }
                              
    $envPkgConfigPath = Get-ConfigFileName -FileNamePrefix "Report Based Redemptions"
    $xml.Save($envPkgConfigPath)
    Write-Host "Running AddSSISJob"
    RunScript -SqlFile "$package\Tools\AddSSISJob.sql" -SqlVariableHash @{"PACKAGEPATH"=$packagePath; "JOBNAME"="ReportBasedRedemptions"; "DTSCONFIGPATH"=$envPkgConfigPath; 
                                                                   "JOBDESCRIPTION"="Job to generate Report Based Redemptions";
                                                     }                                                  
}

function DbBackup{
  $query = "SELECT msdb.dbo.backupmediafamily.physical_device_name,msdb.dbo.backupset.name FROM msdb.dbo.backupmediafamily INNER JOIN msdb.dbo.backupset ON msdb.dbo.backupmediafamily.media_set_id = msdb.dbo.backupset.media_set_id WHERE msdb.dbo.backupset.database_name = `'$Database`' order by msdb.dbo.backupset.backup_finish_date desc"
  Invoke-Expression "sqlcmd.exe -S $DatabaseServer -U $user -P $pass -d master -W -s ',' -h -1 -Q `"$query`" -o crap.txt" 
  $line = Get-Content "crap.txt" | Select-Object -first 1
  Remove-Item "crap.txt"
  $tokens = $line.split(",")
  $name = $tokens[1]
  $file = $tokens[0]
  Invoke-Expression "sqlcmd.exe -S $DatabaseServer -U $user -P $pass -d master -Q `"BACKUP DATABASE [$Database] to DISK =N'$file' WITH NAME = N'$name', NOSKIP, STATS = 10, NOFORMAT`""
}

Set-Location "C:\tc_install\RBR"
$script:ErrorActionPreference = "Stop"
$hash = Init
$package = "RBR"
$current_path = resolve-path "."
$btnum = getRbrProjectId $project
$buildNum = getBuildNum $btnum $hash['pinned']
$buildId = getBuildId $btnum $hash['pinned']

$url = "http://vmteambuildserver/repository/download/$btNum/$buildId"+":id/$package.{build.number}.zip?guest=1"
$filename = "$package.$buildNum.zip"
if(-not (Test-Path "$current_path\$filename")) {
  (new-object net.webclient).DownloadFile($url,"$current_path\$filename")
  Write-Host "Downloading $filename"
  if(-not (Test-Path "$current_path\$package.$buildNum")){
    ExtractPackage "$current_path\$filename" "$current_path\$package.$buildNum"
  }
}
$package = "$current_path\$package.$buildNum"
$DatabaseServer = $hash['rbr.db.instance']
$Database = $hash['rbr.db']
$user = $hash['rbr.db.user']
$pass = $hash['rbr.db.password']
#DbBackup
$output = Invoke-Expression "$package\Tools\SQLCompare\SQLCompare.exe /Scripts1:""$package\DB"" /server2:$DatabaseServer /db2:$Database /username2:$user /password2:$pass /Include:identical /Force /Verbose /ScriptFile:$package\SchemaSyncScript.sql"
$lines = Get-Content -Path "$package\SchemaSyncScript.sql"
for ($i=0; $i -le $lines.Length – 1; $i++){
  if($lines[$i] -match 'acraver'){
    $lines[$i] = $null
  }
}
Set-Content -Path "$package\SchemaSyncScript.sql" -Value $lines
Invoke-Expression "sqlcmd.exe -S $DatabaseServer -U $user -P $pass -d $Database -i $package\SchemaSyncScript.sql"
Install-ReportBasedRedemption
Remove-Item $filename
exit "ErrorCode: " + $LASTEXITCODE

