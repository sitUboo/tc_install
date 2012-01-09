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

function UnInstall() {
    $name = $hash['oms.site.name']
    foreach ($obj in (Get-ChildItem "IIS:\Sites" | Where-Object { $_.name -eq "$name" })){
        Write-Host "Uninstalling $name"
        if($obj.status -eq 'Started'){
            Stop-WebSite -Name $name
        }
        Remove-WebSite -Name $obj.name
        Write-Host "Removing Site Files"
        if(Test-Path ($obj.physicalPath)){
            Remove-Item $obj.physicalPath -recurse -force -exclude *.svclog
        }
    }
}

function Install(){
    $name = $hash['oms.site.name']
    New-WebSite -Name $name -ApplicationPool $hash['oms.app.pool'] -Port $hash['oms.site.port'] -PhysicalPath $packageRoot
    trap [System.Runtime.InteropServices.COMException] {
      Write-Host "Threw the Invalid class string error."
      continue;
    }
}

function UpdateConfiguration(){
    $config = [xml](Get-Content "$packageRoot\Web.config")
    $connStr = $config.configuration.connectionStrings.add | where-object { $_.name -eq "CardlyticsMembership" }
    $cstr = "Data Source="+$hash['oms.db.instance']+";Initial Catalog="+$hash['membership.db']+";Persist Security Info=True;User ID="+$hash['oms.db.username']+";Password="+$hash['oms.db.password']+""
    $connStr.SetAttribute("connectionString",$cstr)
    $connStr = $config.configuration.connectionStrings.add | where-object { $_.name -eq "Oms" }
    $cstr = "Data Source="+$hash['oms.db.instance']+";Initial Catalog="+$hash['oms.db']+";Persist Security Info=True;User ID="+$hash['oms.db.username']+";Password="+$hash['oms.db.password']+";MultipleActiveResultSets=True"
    $connStr.SetAttribute("connectionString",$cstr)
    $connStr = $config.configuration.connectionStrings.add | where-object { $_.name -eq "QueueDatabase" }
    $cstr = "Data Source="+$hash['oms.db.instance']+";Initial Catalog="+$hash['oms.db']+";Persist Security Info=True;User ID="+$hash['oms.db.username']+";Password="+$hash['oms.db.password']+""
    $connStr.SetAttribute("connectionString",$cstr)
    $endPoint = $config.configuration."system.serviceModel".client.endpoint | where-object { $_.binding -eq "wsHttpBinding" }
    $endPoint.SetAttribute("address","http://"+$hash['cling.host']+":"+$hash['cling.site.port']+$hash['ops.service']);
    $logPath = $config.configuration.appSettings.add | where-object { $_.key -eq "LogFilePath" }
    $logPath.SetAttribute("value",$hash['oms.log.file']);
    if($hash['csa.host']){
      $csaUrlFmt = $config.configuration.appSettings.add | where-object { $_.key -eq "CSAUrlFormat" }
      $textValue = $csaUrlFmt.GetAttribute("value");
      $textValue = $textValue.replace("localhost",$hash['csa.host']);
      $textValue = $textValue.replace("52270",$hash['csa.port']);
      $csaUrlFmt.SetAttribute("value",$textValue);
    }
    $dataFolder = $config.configuration.appSettings.add | where-object { $_.key -eq "DataFileFolder" }
    $dataFolder.SetAttribute("value",$hash['oms.data.folder']);
    $config.save("$packageRoot\Web.config");
}

Set-Location "C:\tc_install\OMS"
$script:ErrorActionPreference = "Stop"
$hash = Init $configFile
$package = "Cardlytics.Oms.Web"
$btnum = getOmsProjectId $project
$buildNum = getBuildNum $btnum $hash['pinned']
$buildId = getBuildId $btnum $hash['pinned']
Write-Host "Installation of $package"
$mode = $hash['release.mode']
$packageAddress = "http://vmteambuildserver/repository/download/$btnum/$buildId"+":id/$package.$mode.{build.number}.zip?guest=1";
$current_path = resolve-path "."
(new-object net.webclient).DownloadFile($packageAddress,"$current_path\$package.$mode.$buildNum.zip")
ValidateAndLoadWebAdminModule
UnInstall
$packageRoot = "$current_path\"
$packageRoot += $hash['oms.site.name']
ExtractPackage $package".$mode.$buildNum.zip" "$packageRoot"
UpdateConfiguration
Install
Write-Host "Deploy Complete"

