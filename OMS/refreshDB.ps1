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
  $webclient.credentials = new-object system.net.networkcredential("sdeal", "Jannina1010")
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
  $address = "http://vmteambuildserver/app/rest/buildTypes/id:$configId/builds/status:SUCCESS,pinned:$pin_status/id?guest=1";
  return (new-object net.webclient).DownloadString($address);
}

function getBuildNum($configId, $pin_status){
  $address = "http://vmteambuildserver/app/rest/buildTypes/id:$configId/builds/status:SUCCESS,pinned:$pin_status/number?guest=1";
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

Set-Location "C:\tc_install\OMS"
$script:ErrorActionPreference = "Stop"
$hash = Init $configFile
$package = "OMS-DB"
$btnum = getOmsProjectId $project
$buildNum = getBuildNum $btnum $hash['pinned']
$buildId = getBuildId $btnum $hash['pinned']
Write-Host "Installation of $package"
$packageAddress = "http://vmteambuildserver/repository/download/$btnum/$buildId"+":id/$package.{build.number}.nupkg?guest=1";
$current_path = resolve-path "."
$packageRoot += "$current_path\$package\content"
(new-object net.webclient).DownloadFile($packageAddress,"$current_path\$package`_$buildNum.zip")

ExtractPackage $package"_$buildNum.zip" "$current_path\$package"
$dbinstance = $hash['oms.db.instance']
$db = $hash['oms.db']
$user = $hash['oms.db.username']
$pass = $hash['oms.db.password']
$output = Invoke-Expression "$package\tools\SqlCompare\SQLCompare.exe /Scripts1:""$package\content"" /server2:$dbinstance /db2:$db /username2:$user /password2:$pass /sync /Include:identical /Force /Verbose /ScriptFile:$package\SchemaSyncScript.sql"
Write-Output $output
exit $LASTEXITCODE
