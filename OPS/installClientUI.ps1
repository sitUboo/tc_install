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
$bankuiProjects = @{}

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
    Write-Host $buildType.name $buildType.id
    $clientProjects[$buildType.name] = $buildType.id
  }
  $url = "$baseurl/httpAuth/app/rest/projects/id:project8";
  $result = [xml] $webclient.DownloadString($url)
  foreach ($buildType in ($result.project.buildTypes.buildType)){
    $bankuiProjects[$buildType.name] = $buildType.id
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

function getBankUIProjectId($str){
  return $bankuiProjects[$str];
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
	ConfigureIIS
}

function UnInstall() {
	Stop-WebSite -Name $siteName
	foreach ($virtualFolder in $virtualFolders) {
		if (Test-Path -Path "IIS:\Sites\$siteName\$virtualFolder"){
			Remove-WebApplication -Name "$virtualFolder" -Site "$siteName"
		}
	}
	foreach ($obj in (Get-ChildItem "IIS:\Sites" | Where-Object { $_.name -eq "$siteName" })){
		Write-Host "Uninstalling "  $obj.name
		if($obj.status -eq 'Started'){
			Stop-WebSite -Name $siteName
		}
		Remove-WebSite -Name $obj.name
		Write-Host "Removing Site Files"  $obj.physicalPath
		if(Test-Path ($obj.physicalPath)){
			Remove-Item $obj.physicalPath -recurse -force 
		}
	}
	if(Get-ChildItem IIS:\AppPools | Where-Object { $_.name -eq "$siteName" }) {
		Remove-WebAppPool -Name "$siteName" 
		Write-Host
		Write-Host "[Warning] Removing existing [$siteName] IIS Application Pool" -foregroundcolor yellow
		Write-Host
	}
}

function UnInstall() {
	foreach ($virtualFolder in $virtualFolders) {
		if (Test-Path -Path "IIS:\Sites\$siteName\$virtualFolder"){
			Remove-WebApplication -Name "$virtualFolder" -Site "$siteName"
		}
	}
	foreach ($obj in (Get-ChildItem "IIS:\Sites" | Where-Object { $_.name -eq "$siteName" })){
		if(Test-Path ($obj.physicalPath)){
			Remove-Item $obj.physicalPath -recurse -force 
		}
		Remove-WebSite -Name $siteName
	}
	if(Get-ChildItem IIS:\AppPools | Where-Object { $_.name -eq "$siteName" }) {
		Remove-WebAppPool -Name "$siteName" 
		Write-Host
		Write-Host "[Warning] Removing existing [$siteName] IIS Application Pool" -foregroundcolor yellow
		Write-Host
	}
}

function Install(){
	CreateApplicationPool($siteName)
	New-WebSite -Name $siteName -ApplicationPool $siteName -Port 80 -force -PhysicalPath $packageRoot
	trap [System.Runtime.InteropServices.COMException] {
             Write-Host "Threw the Invalid class string error."
             continue;
        }
	foreach ($virtualFolder in $virtualFolders) {
		$commitpath = 'IIS:\Sites\' + $siteName + '\' + $virtualFolder;
		if ($virtualFolder -eq "greenbow"){
			UpdateRewriteUrlPort $hash['clientui.ops.gb'] "Proxy" "$packageRoot\greenbow"
		}
		if ($virtualFolder -eq "mj"){
			UpdateRewriteUrlPort $hash['clientui.ops.mj'] "Proxy2" "$packageRoot\mj"
		}
		ConvertTo-WebApplication -PSPath $commitpath
	}
	if((Get-Website -Name $siteName | select State) -eq "Stopped"){
	    Write-Host "Starting $siteName"
		Start-WebSite -Name $siteName
	}
}

function GetOPSWebPort($sitename){
	$mysteryPort = Get-WebBinding $sitename | select 'bindingInformation'
	$port = $mysteryPort.bindingInformation
	$port = $port.TrimStart("*:")
	$port = $port.TrimEnd(":")
	return $port
}

function UpdateConfiguration($path){
	$webconfig = [xml](Get-Content "$path\Web.config")
	$opsConnStr = $webconfig.configuration.connectionStrings.add | where-object { $_.name -eq "Ops" }
	$cstr = "Data Source="+$hash['batch.db.instance']+";Initial Catalog="+$hash['batch.db']+";Persist Security Info=True;User ID="+$hash['ops.db.username']+";Password="+$hash['ops.db.password']+""
	$opsConnStr.SetAttribute("connectionString",$cstr)
	$webconfig.save("$path\Web.config");
}

function UpdateRewriteUrlPort($site, $rule, $path){
	$defaultIp = '55065'
	$newIp = GetOPSWebPort $site
	Write-Host "$site is using port " $newIp
	UpdateTopLevelWebConfig $rule $newIp
	foreach ($file in (gci $path -rec -inc "Web.config")) {
		$text = get-content $file
		if ($text -match $defaultIp) {
			Write-Output "Replaceing $defaultIp with $newIp"
			$text -replace $defaultIp, $newIp | Out-File -encoding UTF8 $file
		}
	}
	UpdateConfiguration($path)
}

function UpdateTopLevelWebConfig ($rulename,$port){
	$servername = $hash['ops.host']
	Write-Host "Looking for rule $rulename"
	Write-Host "With port $port"
	$fullport = "http://" + $servername+":"+$port+"/public{R:2}"
	$xmldata = [xml](Get-Content "$packageRoot\Web.config")
	$rule = $xmldata.configuration."system.webServer".rewrite.rules.rule | where-object { $_.name -eq $rulename }
	$rule.action.SetAttribute("url",$fullport)
	$xmldata.save("$packageRoot\Web.config")
}

function VerifyHasIISModule($moduleNames) {
	foreach($moduleName in $moduleNames) {
	if(-not(Get-WebConfiguration -Filter "system.webServer/globalModules/add[@name='$moduleName']" -PSPath IIS:\)) {
		Write-Host "The IIS module $moduleName is required. The Deployment script will now exit" -foregroundcolor red
		Write-Host
		Wait-KeyPress("Press any-key to navigate to the download site...")
		switch($moduleName) {
			"RewriteModule" { [System.Diagnostics.Process]::Start("http://www.iis.net/download/urlrewrite") }
			"ApplicationRequestRouting" { [System.Diagnostics.Process]::Start("http://www.iis.net/download/ApplicationRequestRouting") }
		}
		Exit
	}
	}
}

function ConfigureIIS() {
	VerifyHasIISModule("RewriteModule", "ApplicationRequestRouting")
	if(-not((Get-WebConfigurationProperty -Filter "system.webServer/proxy" -Name "enabled").Value)) {
	Set-WebConfigurationProperty -Filter "system.webServer/proxy" -Name "enabled" -Value "True"
	}
}

try{
  Set-Location "C:\tc_install\OPS"
  #$script:ErrorActionPreference = "Stop"
  $hash = Init
  $package = "Cardlytics.ClientUI.Web"
  $btnum = getClientProjectId $project
  $buildNum = getBuildNum $btnum $hash['pinned']
  $buildId = getBuildId $btnum $hash['pinned']
  $packageAddress = "http://vmteambuildserver/repository/download/$btnum/$buildId"+":id/$package.{build.number}.zip?guest=1";
  $current_path = resolve-path "."
  $packageRoot = "$current_path\$package"
  (new-object net.webclient).DownloadFile($packageAddress,"$current_path\$package.$buildNum.zip")
  $siteName = "Cardlytics.ClientUI.Web"
  $virtualFolders = @("greenbow","mj")
  
  ValidateAndLoadWebAdminModule
  UnInstall
  
  ExtractPackage $package".$buildNum.zip" "$packageRoot"
  Install
  
  #Start-WebSite -Name $siteName
  Write-Output "Deploy Complete"
}catch{
  throw "Deployment Error";
}
