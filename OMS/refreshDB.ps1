param 
( 
	[parameter(Mandatory = $true)]
	[string]
	$project,
	[parameter(Mandatory = $false)]
	[string]
	$configFile,
  [parameter(Mandatory = $true)]
  [System.Management.Automation.PSCredential]
  $appCred
)

$opsProjects = @{}
$omsProjects = @{}
$clientProjects = @{}

function ExtractPackage($package,$path){
    import-module Pscx
    if(-not (Test-Path "$path")){
        Write-Host "Creating directory $path"
        New-Item "$path" -type directory
    }
    Write-Host "Extracting archive $package to $path"
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
  $webclient.credentials = $appCred
  $result = [xml] $webclient.DownloadString($url)
  foreach ($buildType in ($result.project.buildTypes.buildType)){
    $opsProjects[$buildType.name] = $buildType.id
  }
  $url = "$baseurl/httpAuth/app/rest/projects/id:project3";
  $result = [xml] $webclient.DownloadString($url)
  foreach ($buildType in ($result.project.buildTypes.buildType)){
    $omsProjects[$buildType.name] = $buildType.id
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

function Load-ApplicationData ($dataDirectory,$dbserver,$user,$pass){
  Write-Output "Updating Application Data"
  $tableHash = @{}
  foreach ( $sqlfile in (Get-ChildItem "$dataDirectory\*.*.sql")){
    $sqlfile -match ('([A-Za-z]*).([A-Za-z]*)_Data.sql')
    $schema= $matches[1]
    $table = $matches[2]
    if($table -eq ""){
      Write-Host "Unable to extract table name... fatal error."
      exit -1;
    }
    $tableHash[$table] = "$schema.$table"
  }
  $cmdText = "SELECT KCU1.* FROM INFORMATION_SCHEMA.REFERENTIAL_CONSTRAINTS RC JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE KCU1 ON KCU1.CONSTRAINT_CATALOG = RC.CONSTRAINT_CATALOG AND KCU1.CONSTRAINT_SCHEMA = RC.CONSTRAINT_SCHEMA AND KCU1.CONSTRAINT_NAME = RC.CONSTRAINT_NAME JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE KCU2 ON KCU2.CONSTRAINT_CATALOG = RC.UNIQUE_CONSTRAINT_CATALOG AND KCU2.CONSTRAINT_SCHEMA = RC.UNIQUE_CONSTRAINT_SCHEMA AND KCU2.CONSTRAINT_NAME = RC.UNIQUE_CONSTRAINT_NAME AND KCU2.ORDINAL_POSITION = KCU1.ORDINAL_POSITION where KCU2.TABLE_NAME in ('" + [String]::join("','",$tables) + "');"
  
  $conn = New-Object System.Data.SqlClient.SqlConnection
  $conn.ConnectionString = "Data Source=$dbinstance;Database=$db;User ID=$user;Password=$pass"
  $conn.Open()
  $cmd = New-Object System.Data.SqlClient.SqlCommand($cmdText,$conn)
  $rdr = $cmd.ExecuteReader()
  $disableConstraints = @()
  $enableConstraints = @()
  while($rdr.Read())
  {
    $constraint = $rdr['CONSTRAINT_NAME'].ToString()
    $table = $rdr['TABLE_NAME'].ToString()
    $disableConstraints += "ALTER TABLE " + $tableHash[$table] + " NOCHECK CONSTRAINT $constraint;"
    $enableConstraints += "ALTER TABLE " + $tableHash[$table] + " CHECK CONSTRAINT $constraint;"
  }
  $conn.Close()
  
  $conn.Open()
  Write-Host "Disabling constraints"
  foreach ($cmdText in $disableConstraints){
    Write-Host $cmdText
    $cmd = New-Object System.Data.SqlClient.SqlCommand($cmdText,$conn)
    $result = $cmd.ExecuteNonQuery()
  }
  foreach ($table in $tableHash.keys){
    Write-Host "Deleting data from $table..."
    $cmdText = "DELETE FROM " + $tableHash[$table] + ";"
    $cmd = New-Object System.Data.SqlClient.SqlCommand($cmdText,$conn)
    $cmd.ExecuteNonQuery()
  }
  foreach ( $sqlfile in (Get-ChildItem "$dataDirectory\*.*.sql")){
    foreach ($line in (Get-Content "$sqlfile")){
      Write-Host "Running $line"
      $cmd = New-Object System.Data.SqlClient.SqlCommand($line,$conn)
      $result = $cmd.ExecuteNonQuery()
    }
  }
  Write-Host "Enabling constraints"
  foreach ($cmdText in $enableConstraints){
    Write-Host $cmdText
    $cmd = New-Object System.Data.SqlClient.SqlCommand($cmdText,$conn)
    $result = $cmd.ExecuteNonQuery()
  }
  $conn.Close()
}

Set-Location "C:\tc_install\OMS"
$script:ErrorActionPreference = "Stop"
$hash = Init $configFile
$package = "OMS-DB"
$btnum = getOmsProjectId $project
$buildNum = getBuildNum $btnum $hash['pinned']
$buildId = getBuildId $btnum $hash['pinned']
$packageAddress = "http://vmteambuildserver/repository/download/$btnum/$buildId"+":id/$package.{build.number}.nupkg?guest=1";
$current_path = resolve-path "."
$packageRoot += "$current_path\$package\content"

if(-not (Test-Path "$current_path\$package`_$buildNum.zip")){
  Write-Host "Downloading $package`_$buildNum.zip"
  (new-object net.webclient).DownloadFile($packageAddress,"$current_path\$package`_$buildNum.zip")
}

if(Test-Path "$current_path\$package"){ 
  Remove-Item "$current_path\$package" -recurse
}
ExtractPackage $package"_$buildNum.zip" "$current_path\$package"

$dbinstance = $hash['oms.db.instance']
$db = $hash['oms.db']
$user = $hash['oms.db.username']
$pass = $hash['oms.db.password']

Load-ApplicationData "$package\content\Data" $dbinstance $user $pass

$output = Invoke-Expression "$package\tools\SqlCompare\SQLCompare.exe /Options:IgnoreDatabaseAndServerName /Scripts1:""$package\content"" /server2:$dbinstance /db2:$db /username2:$user /password2:$pass /sync /Include:identical /Force /Verbose /ScriptFile:$package\SchemaSyncScript.sql"
Write-Output $output

Remove-Item $package"_$buildNum.zip"

exit $LASTEXITCODE
