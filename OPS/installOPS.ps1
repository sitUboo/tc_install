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

function UnInstall() {
    $name = $hash['ops.site.name']
    foreach ($obj in (Get-ChildItem "IIS:\Sites" | Where-Object { $_.name -eq "$name" })){
        Write-Host "Uninstalling "  $obj.name
        if($obj.status -eq 'Started'){
            Stop-WebSite -Name $name
        }
        Remove-WebSite -Name $obj.name
        Write-Host "Removing Site Files"  $obj.physicalPath
        if(Test-Path ($obj.physicalPath)){
            Remove-Item $obj.physicalPath -recurse -force 
        }
    }
	if(Get-ChildItem IIS:\AppPools | Where-Object { $_.name -eq "$name" }) {
		Remove-WebAppPool -Name "$name" 
		Write-Host
		Write-Host "[Warning] Removing existing [$name] IIS Application Pool" -foregroundcolor yellow
		Write-Host
	}
}

function Install(){
    $name = $hash['ops.site.name']
    CreateApplicationPool($name)
    New-WebSite -Name $name -ApplicationPool $name -Port $hash['ops.site.port'] -PhysicalPath $packageRoot
	trap [System.Runtime.InteropServices.COMException] {
            Write-Host "Threw the Invalid class string error."
            continue;
        }
	sleep 10
	if((Get-Website -Name $name | select State) -eq "Stopped"){
	    Write-Host "Starting $name"
	    Start-WebSite -Name $name
	}
}

function UpdateConfiguration(){
    $webconfig = [xml](Get-Content "$packageRoot\Web.config")
    $opsConnStr = $webconfig.configuration.connectionStrings.add | where-object { $_.name -eq "Ops" }
    $cstr = "Data Source="+$hash['batch.db.instance']+";Initial Catalog="+$hash['batch.db']+";Persist Security Info=True;User ID="+$hash['ops.db.username']+";Password="+$hash['ops.db.password']+""
    $opsConnStr.SetAttribute("connectionString",$cstr)
    $portalConnStr = $webconfig.configuration.connectionStrings.add | where-object { $_.name -eq "Portal" }
    $cstr = "Data Source="+$hash['portal.db.instance']+";Initial Catalog="+$hash['portal.db']+";Persist Security Info=True;User ID="+$hash['ops.db.username']+";Password="+$hash['ops.db.password']+""
    $portalConnStr.SetAttribute("connectionString",$cstr)
	if($hash['installMode'] -eq 'debug'){
		$node = $webconfig.SelectSingleNode('//soapExtensionTypes/add[@type="Cardlytics.Framework.Web.WSCompressionExtension, Cardlytics.Framework"]')
		$node.ParentNode.RemoveChild($node)
	}
	$webconfig.save("$packageRoot\Web.config");
}

Set-Location "C:\tc_install\OPS"
$script:ErrorActionPreference = "Stop"
$hash = Init
$package = $hash['ops.site.name']
$btnum = getOpsProjectId $project
$buildNum = getBuildNum $btnum $hash['pinned']
$buildId = getBuildId $btnum $hash['pinned']
#OPS is not doing multiple build configurations yet
#$mode = $hash['release.mode']
$packageAddress = "http://vmteambuildserver/repository/download/$btnum/$buildId"+":id/$package.{build.number}.zip?guest=1";
$current_path = resolve-path "."
$packageRoot = "$current_path\$package"
(new-object net.webclient).DownloadFile($packageAddress,"$current_path\$package.$buildNum.zip")

ValidateAndLoadWebAdminModule
UnInstall
ExtractPackage $package".$buildNum.zip" "$packageRoot"
UpdateConfiguration
Install
Write-Output "Deploy Complete"

