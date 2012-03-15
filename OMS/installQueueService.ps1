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
#we killed the clientui app
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

function Install($path){
    Write-Host "Installing"
    $return = Invoke-Expression "installUtil.exe $path\Cardlytics.QueueService.exe"
    Write-Output $return
}

function UpdateConfiguration($service,$service_dir){
    $file = "Cardlytics.QueueService.exe.config"
    $config = [xml](Get-Content "$packageRoot\$file")
    $serviceName = $config.configuration.appSettings.add | where-object { $_.key -eq "ServiceName" }
    $serviceName.SetAttribute("value",$service);
    $execDelay = $config.configuration.appSettings.add | where-object { $_.key -eq "ExecutionDelay" }
    $execDelay.SetAttribute("value",$hash['queue.executiondelay']);
    $retryDelay = $config.configuration.appSettings.add | where-object { $_.key -eq "RetryDelay" }
    $retryDelay.SetAttribute("value",$hash['queue.retrydelay']);
    $logPath = $config.configuration.appSettings.add | where-object { $_.key -eq "LogFilePath" }
    $logPath.SetAttribute("value",$hash['queue.log.path']+$service_dir+".log");
    $connStr = $config.configuration.connectionStrings.add | where-object { $_.name -eq "Oms" }
    $cstr = "Data Source="+$hash['oms.db.instance']+";Initial Catalog="+$hash['oms.db']+";Persist Security Info=True;User ID="+$hash['oms.db.username']+";Password="+$hash['oms.db.password']+""
    $connStr.SetAttribute("connectionString",$cstr);
    $config.save("$packageRoot\$file");
    $connStr = $config.configuration.connectionStrings.add | where-object { $_.name -eq "QueueDatabase" }
    $cstr = "Data Source="+$hash['oms.db.instance']+";Initial Catalog="+$hash['oms.db']+";Persist Security Info=True;User ID="+$hash['oms.db.username']+";Password="+$hash['oms.db.password']+""
    $connStr.SetAttribute("connectionString",$cstr);
    $config.save("$packageRoot\$file");
    $endPoint = $config.configuration."system.serviceModel".client.endpoint | where-object { $_.binding -eq "wsHttpBinding" }
    $endPoint.SetAttribute("address","http://"+$hash['cling.host']+":"+$hash['cling.site.port']+$hash['ops.service']);
    $config.save("$packageRoot\$file");
}

function UnInstall($service,$path){
  $iterator = 0
  while (Get-Service $service -ErrorAction SilentlyContinue | Where-Object {$_.status -ne "stopped"}) {
    $iterator += 1
    if($iterator > 4){
      Write-Host "Failed to stop $service $iterator times, giving up."
      exit 0
    }
    Write-Host "Stopping `"$service`""
    Invoke-Expression "sc.exe stop `"$service`""
    sleep 15
  }
  Write-Host "Uninstalling"
  $return = Invoke-Expression "installUtil.exe /u $path\Cardlytics.QueueService.exe"
  Write-Host $return
}

function StartService($service){
    Write-Host "Found " $service
    Write-Host "Starting `"$service`""
    Invoke-Expression "sc.exe start `"$service`""
}

try{
  Set-Location "C:\tc_install\OMS"
  #$script:ErrorActionPreference = "Stop"
  $hash = Init $configFile
  $package = "Cardlytics.QueueService"
  $btnum = getOmsProjectId $project
  $buildNum = getBuildNum $btnum $hash['pinned']
  $buildId = getBuildId $btnum $hash['pinned']
  $mode = $hash['release.mode']
  $packageAddress = "http://vmteambuildserver/repository/download/$btnum/$buildId"+":id/$package.$mode.{build.number}.zip?guest=1"
  $current_path = resolve-path "."
  Write-Host "Downloading $package.$mode.$buildNum.zip"
  (new-object net.webclient).DownloadFile($packageAddress,"$current_path\$package.$mode.$buildNum.zip")
  
  if(-not(Test-Path 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\InstallUtil.exe')) {
    Write-Host "Unable to confirm expected installUtil program.";
  }else{
    $env:path = $env:Path + ";C:\Windows\Microsoft.NET\Framework64\v4.0.30319";
  }
  
  foreach ($service in ($hash['queue.services'].split(','))){
    $service_dir = $service.replace(" ","_");
    $packageRoot = "$current_path\$service_dir"
    UnInstall $service $packageRoot
    ExtractPackage $package".$mode.$buildNum.zip" "$current_path\$service_dir"
    UpdateConfiguration $service $service_dir
    Install $packageRoot
    StartService $service
  }
  Remove-Item $package".$mode.$buildNum.zip"
  Write-Output "Deploy Complete"
}catch{
  throw "Deployment Error"
}

