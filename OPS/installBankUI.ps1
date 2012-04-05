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

function ConvertToMin{
  $dirs = ('bac-crd','bac-dbt','bac-available','bac-earned','bac-expired','bac-pref')
  $public_dir = "$packageRoot\public"

  foreach ($dir in $dirs){
    $wrk_dir = "$public_dir\$dir"
    $min_file = get-childitem "$wrk_dir\*min*.js" -name
    if(!$min_file){
      Write-Host "Unable to find min file!!! FATAL ERROR"
      exit -1
    }
    $counter = 0
    $file = "$wrk_dir\index.html"
    $outfile = "$wrk_dir\index_new.html"
    get-content "$file" -encoding UTF8 | Foreach-Object {
      if ($_ -match "../js/bac.cardlytics"){
        if ($_ -match "preload"){
          $_ | Out-File -append "$outfile" -encoding UTF8
        }
      # do nothing
      }elseif ($_ -match "../$dir/$dir"){
        $str = [regex]::Replace($_, "..\/$dir\/$dir.*.js'", "../$dir/$min_file'");
        if($counter -lt 1){
          $str | Out-File -append $outfile -encoding UTF8
        }
        $counter =+ 1
      }else{
        $_ | Out-File -append "$outfile" -encoding UTF8
      }
    }
    move-item $outfile $file -force
  }
}

try {
  Set-Location "C:\tc_install\OPS"
  #$script:ErrorActionPreference = "Stop"
  $hash = Init
  $package = $project
  $btnum = getBankUIProjectId $project
  $buildNum = getBuildNum $btnum $hash['pinned']
  $buildId = getBuildId $btnum $hash['pinned']
  # QA needs the debug build even in a stable environment
  $mode = 'Debug'#$hash['release.mode']
  $packageAddress = "http://vmteambuildserver/repository/download/$btnum/$buildId"+":id/$package.{build.number}-$mode.zip?guest=1";
  $current_path = resolve-path "."
  $packageRoot = "$current_path\"+$hash['ops.site.name']
  (new-object net.webclient).DownloadFile($packageAddress,"$current_path\$package.$buildNum.zip")
  
  Write-Host "Deploying Bank UI..."
  Write-Host "Extracting $package.$buildNum.zip to $packageRoot"
  ExtractPackage $package".$buildNum.zip" "$packageRoot"
  Remove-Item $package".$buildNum.zip"
  if($mode -ne "Release"){
    Write-Output "Updating index.html to use min files..."
    ConvertToMin
  }
  Write-Output "Deploy Complete"
}catch{
  throw "Deployment Error";
}

