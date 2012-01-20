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
  $url = "$baseurl/httpAuth/app/rest/projects/id:project5";
  $result = [xml] $webclient.DownloadString($url)
  foreach ($buildType in ($result.project.buildTypes.buildType)){
    $clientProjects[$buildType.name] = $buildType.id
  }
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

function Install-SyncDtsPackage {

    $sub1Path = (Resolve-Path "$package\SSIS\SyncBatchPortal\SyncDboPortal_Sub_1.dtsx")
    $sub2Path = (Resolve-Path "$package\SSIS\SyncBatchPortal\SyncDboPortal_Sub_2.dtsx")
    $packagePath = (Resolve-Path "$package\SSIS\SyncBatchPortal\SyncDboPortal.dtsx")
    $packageConfigPath = (Resolve-Path "$package\SSIS\SyncBatchPortal\SyncDboPortal_Config.dtsConfig")
    
    $xml = [xml](get-content $packageConfigPath)

    Set-DtsPackageParams -XmlConfig $xml -ParamHash @{ "\Package.Variables[SyncDboPortal_Sub_1].Properties[Value]" = $sub1Path;
                                                        "\Package.Variables[SyncDboPortal_Sub_2].Properties[Value]" = $sub2Path;
                                                        "\Package.Variables[User::OPSBatch_DB].Properties[Value]" = $hash['batch.db'];
                                                        "\Package.Variables[User::OPSBatch_Server].Properties[Value]" = $DatabaseServer;
                                                        "\Package.Variables[User::OPSPortal_DB].Properties[Value]" = $hash['portal.db'];
                                                        "\Package.Variables[User::OPSPortal_Server].Properties[Value]" = $DatabaseServer;
                                                  }

  $envPkgConfigPath = Get-ConfigFileName -FileNamePrefix "SyncDboPortal_Config"
  $xml.Save($envPkgConfigPath)
	
  RunScript -SqlFile "$package\DB\Build\Tools\AddSSISJob.sql" -SqlVariableHash @{"PACKAGEPATH"=$packagePath; "JOBNAME"="Sync Batch/Portal"; "DTSCONFIGPATH"=$envPkgConfigPath; 
                                                                   "JOBDESCRIPTION"="Job to synch batch and portal tables";
                                                                  }
}


function Install-EtlFItoStageDtsPackage {

    $packagePath = (Resolve-Path "$package\SSIS\ETL\ETL_MoveTrxnFromFIToStage.dtsx")
    $packageConfigPath = (Resolve-Path "$package\SSIS\ETL\ETL_MoveTrxnFromFIToStage_Config.dtsConfig")
    
    $xml = [xml](get-content $packageConfigPath)

    Set-DtsPackageParams -XmlConfig $xml -ParamHash @{ "\Package.Variables[User::OPSBatch_DB].Properties[Value]" = $Database;
                                                        "\Package.Variables[User::OPSBatch_Server].Properties[Value]" = $DatabaseServer;
                                                     }
                              
    $envPkgConfigPath = Get-ConfigFileName -FileNamePrefix "ETL_MoveTrxnFromFIToStage_Config"
    $xml.Save($envPkgConfigPath)                                 
    RunScript -SqlFile "$package\DB\Build\Tools\AddSSISJob.sql" -SqlVariableHash @{"PACKAGEPATH"=$packagePath; "JOBNAME"="ETL_MoveTrxnFromFIToStage"; "DTSCONFIGPATH"=$envPkgConfigPath; 
                                                                   "JOBDESCRIPTION"="Job to move transactions from FITrxn to STAGETrxn";
                                                                 }                                                  
}

function Install-EtlStagetoDboDtsPackage {

    $packagePath = (Resolve-Path "$package\SSIS\ETL\ETL_MoveTrxnFromStageToDbo.dtsx")
    $packageConfigPath = (Resolve-Path "$package\SSIS\ETL\ETL_MoveTrxnFromStageToDbo_Config.dtsConfig")
    
    $xml = [xml](get-content $packageConfigPath)

    Set-DtsPackageParams -XmlConfig $xml -ParamHash @{ "\Package.Variables[User::OPSBatch_DB].Properties[Value]" = $Database;
                                                        "\Package.Variables[User::OPSBatch_Server].Properties[Value]" = $DatabaseServer;
                                                     }
                              
    $envPkgConfigPath = Get-ConfigFileName -FileNamePrefix "ETL_MoveTrxnFromStageToDbo_Config"
    $xml.Save($envPkgConfigPath)                                     
    RunScript -SqlFile "$package\DB\Build\Tools\AddSSISJob.sql" -SqlVariableHash @{"PACKAGEPATH"=$packagePath; "JOBNAME"="ETL_MoveTrxnFromStageToDbo"; "DTSCONFIGPATH"=$envPkgConfigPath; 
                                                                   "JOBDESCRIPTION"="Job to move transactions from STAGETrxn to dbo.Trxn";
                                                     }                                                  
}

function Install-GenerateConsumerAlertsDtsPackage {
    $packagePath = (Resolve-Path "$package\SSIS\Spidey\ConsumerAlerts\GenerateConsumerAlerts.dtsx")
    $packageConfigPath = (Resolve-Path "$package\SSIS\Spidey\ConsumerAlerts\GenerateConsumerAlerts_Config.dtsConfig")
    
    $xml = [xml](get-content $packageConfigPath)

    Set-DtsPackageParams -XmlConfig $xml -ParamHash @{ "\Package.Connections[OPS Batch DB].Properties[InitialCatalog]" = $Database;
                                                        "\Package.Connections[OPS Batch DB].Properties[ServerName]" = $DatabaseServer;
                                                        "\Package.Variables[User::AlertInfoFileName].Properties[Value]" = $hash['alert.file.name'];
                                                        "\Package.Variables[User::OfferInfoFileName].Properties[Value]" = $hash['offerinfo.file.name'];
                                                        "\Package.Variables[User::TargetPath].Properties[Value]" = $hash['alert.targetpath'];
                                                     }
                              
    $envPkgConfigPath = Get-ConfigFileName -FileNamePrefix "GenerateConsumerAlerts_Config"
    $xml.Save($envPkgConfigPath)                                     
    RunScript -SqlFile "$package\DB\Build\Tools\AddSSISJob.sql" -SqlVariableHash @{"PACKAGEPATH"=$packagePath; "JOBNAME"="GenerateConsumerAlerts"; "DTSCONFIGPATH"=$envPkgConfigPath; 
                                                                   "JOBDESCRIPTION"="Job to generate consumer alerts";
                                                     }                                                  
}

function Install-GenerateRewardsFileDtsPackage {
    $packagePath = (Resolve-Path "$package\SSIS\Spidey\RewardsFile\GenerateRewardsFile.dtsx")
    $packageConfigPath = (Resolve-Path "$package\SSIS\Spidey\RewardsFile\GenerateRewardsFile_Config.dtsConfig")
    
    $xml = [xml](get-content $packageConfigPath)

    Set-DtsPackageParams -XmlConfig $xml -ParamHash @{ "\Package.Variables[User::Credit_File_Name].Properties[Value]" = $hash['credit.file.name'];
                                                        "\Package.Variables[User::Debit_File_Name].Properties[Value]" = $hash['debit.file.name'];
                                                        "\Package.Variables[User::Output_File_Path].Properties[Value]" = $hash['output.file.path'];
                                                     }
                              
    $envPkgConfigPath = Get-ConfigFileName -FileNamePrefix "GenerateRewardsFile_Config"
    $xml.Save($envPkgConfigPath)                                     
    RunScript -SqlFile "$package\DB\Build\Tools\AddSSISJob.sql" -SqlVariableHash @{"PACKAGEPATH"=$packagePath; "JOBNAME"="GenerateRewardsFile"; "DTSCONFIGPATH"=$envPkgConfigPath; 
                                                                   "JOBDESCRIPTION"="Job to generate rewards file";
                                                     }                                                  
}

function CheckLogs {
  $webclient = new-object system.net.webclient
  $webclient.credentials = new-object system.net.networkcredential("sdeal", "Jannina1111")
  $result = [Xml]($webclient.DownloadString("http://vmteambuildserver/httpAuth/app/rest/builds?locator=running:true"))
  foreach ($build in ($result.builds.build)){
    $buildno = $build.id
    $log = $webclient.DownloadString("http://vmteambuildserver/httpAuth/downloadBuildLog.html?buildId=$buildno")
    foreach ($line in ($log.split("`n"))){
      if(($line -cmatch "Error:") -or ($line -cmatch "DotNetMethodException")){
        Write-Host "##teamcity[message text='Error Detected: Marking deployment as failed.' errorDetails='line start $line line end' status='ERROR']";
        exit -1;
      }
    }
  }
  Write-Host "##teamcity[message text='Completed Log Check' status='INFO']";
}


Set-Location "C:\tc_install\OPS"
$script:ErrorActionPreference = "Stop"
$hash = Init
$packages= @("OPS-Import-DB","OPS-Portal-DB","OPS-Batch-DB")
$current_path = resolve-path "."
$btnum = getOpsProjectId $project
$buildNum = getBuildNum $btnum $hash['pinned']
$buildId = getBuildId $btnum $hash['pinned']
$username = $hash['ops.db.username']
$password = $hash['ops.db.password']

foreach ($package in $packages){
    $url = "http://vmteambuildserver/repository/download/$btNum/$buildId"+":id/$package.{build.number}.zip?guest=1"
    $filename = "$package.$buildNum.zip"
    $hash[$package] = "$package.$buildNum"
    Write-Host "Downloading $filename"
    (new-object net.webclient).DownloadFile($url,"$current_path\$filename")
    ExtractPackage "$current_path\$filename" "$current_path\$package.$buildNum"
}
#portal
$package = $hash["OPS-Portal-DB"]
$DatabaseServer = $hash['portal.db.instance']
$Database = $hash['portal.db']
$user = $hash['ops.db.username']
$pass = $hash['ops.db.password']
$output = Invoke-Expression "$package\DB\Build\tools\SqlCompare\SQLCompare.exe /Scripts1:""$package\DB"" /server2:$DatabaseServer /db2:$Database /username2:$user /password2:$pass /sync /Include:identical /Force /Verbose /ScriptFile:$package\SchemaSyncScript-Portal.sql"
Write-Output $output

#import
$package = $hash["OPS-Import-DB"]
$DatabaseServer = $hash['import.db.instance']
$Database = $hash['import.db']
$user = $hash['ops.db.username']
$pass = $hash['ops.db.password']
$output = Invoke-Expression "$package\DB\Build\tools\SqlCompare\SQLCompare.exe /Scripts1:""$package\DB"" /server2:$DatabaseServer /db2:$Database /username2:$user /password2:$pass /sync /Include:identical /Force /Verbose /ScriptFile:$package\SchemaSyncScript-Import.sql"
Write-Output $output

#batch
$package = $hash["OPS-Batch-DB"]
$DatabaseServer = $hash['batch.db.instance']
$Database = $hash['batch.db']
$user = $hash['ops.db.username']
$pass = $hash['ops.db.password']

if(-not( Test-Path "$package\DB\SSIS Packages")) {
  rename-item "$package\DB\SSIS%20Packages" "SSIS Packages"
  rename-item "$package\DB\Stored%20Procedures" "Stored Procedures"
}
#Invoke-Expression "$package\DB\Build\tools\SqlCompare\SQLCompare.exe /ignoreParserErrors /Options:IgnoreComments,IgnoreDatabaseAndServerName /Scripts1:""$package\DB"" /server2:$DatabaseServer /db2:$Database /username2:$user /password2:$pass /Include:identical /Force /ScriptFile:$package\SchemaSyncScript-Batch.sql"
Invoke-Expression "$package\DB\Build\tools\SqlCompare\SQLCompare.exe /ignoreParserErrors /Options:Default,IgnoreComments /Scripts1:""$package\DB"" /server2:$DatabaseServer /db2:$Database /username2:$user /password2:$pass /Include:identical /Force /ScriptFile:$package\SchemaSyncScript-Batch.sql"
Get-Content "$package\SchemaSyncScript-Batch.sql" | ForEach-Object { $_ -replace "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE", "SET TRANSACTION ISOLATION LEVEL READ COMMITTED" } | Set-Content "$package\SchemaSyncScript-Batch-mod.sql"

# execute change set
Invoke-Expression "sqlcmd.exe -S $DatabaseServer -U $user -P $pass -d $Database -i $package\SchemaSyncScript-Batch-mod.sql"

Install-SyncDtsPackage
Install-EtlFItoStageDtsPackage
Install-EtlStagetoDboDtsPackage
Install-GenerateConsumerAlertsDtsPackage
Install-GenerateRewardsFileDtsPackage
foreach ($package in $packages){
    Remove-Item $package".$buildNum.zip"
}
exit "ErrorCode: " + $LASTEXITCODE

