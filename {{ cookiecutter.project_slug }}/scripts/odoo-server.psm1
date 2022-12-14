# cookiecutter params
$CONFIG_FILE_NAME = "{{ cookiecutter.project_slug }}.json"
$DB_NAME          = "{{ cookiecutter.db_name }}"
$DB_USER          = "{{ cookiecutter.db_user }}"
$DB_PASS          = "{{ cookiecutter.db_pass }}"

# global constants
$DEFAULT_BRANCH   = "16.0"
$PATH_ROOT        = Join-Path $PSScriptRoot ".."
$PATH_VENV        = Join-Path $PATH_ROOT "venv"
$PATH_ODOO        = Join-Path $PATH_ROOT "odoo"
$PATH_ADDONS      = Join-Path $PATH_ROOT "addons"
$PATH_DATA        = Join-Path $PATH_ROOT "data"
$CONFIG_FILE      = Join-Path $PATH_ROOT $CONFIG_FILE_NAME

function localGitSource($path) {
    # relative path does not work. use absolute path only
    return "file://$($path.Replace('\', '/'))"
}

function Get-DefaultConfig {
    $branch = $DEFAULT_BRANCH
    $default = (
        [ordered]@{
            "db" = [ordered]@{
                "server" = "127.0.0.1"
                "port"   = 5432
                "root"   = "postgres"
                "name"   = $DB_NAME
                "user"   = $DB_USER
                "pass"   = $DB_PASS
            }
            "server" = [ordered]@{
                "http-port"        = 8069
                "longpolling-port" = 8072
            }
            "override-recipes" = [ordered]@{
                "15.0" = [ordered]@{
                    "werkzeug"     = "<2.0.0"
                    "urllib3"      = "==1.26.11"
                }
                "16.0" = [ordered]@{
                    "werkzeug"     = "<2.0.0"
                    "urllib3"      = "==1.26.11"
                    "cryptography" = "==36.0.2"
                }
            }
            "override" = [ordered]@{}
            "odoo" = [ordered]@{
                "source" = localGitSource (Join-Path $PSScriptRoot ".." ".." "odoo-src" "odoo")
                "branch" = $branch
            }
            "addons" = [ordered]@{
                "enterprise" = [ordered]@{
                    "source" = localGitSource (Join-Path $PSScriptRoot ".." ".." "odoo-src" "enterprise")
                    "branch" = $branch
                    "dirs"   = @(".")
                }
                "design-themes" = [ordered]@{
                    "source" = localGitSource (Join-Path $PSScriptRoot ".." ".." "odoo-src" "design-themes")
                    "branch" = $branch
                    "dirs"   = @(".")
                }
                "l10n-thailand" = [ordered]@{
                    "source" = localGitSource (Join-Path $PSScriptRoot ".." ".." "odoo-src" "l10n-thailand")
                    "parts"  = @("l10n_th_withholding_tax")
                    "branch" = $branch
                    "dirs"   = @(".")
                    "requirements" = @("requirements.txt")
                }
            }
        }
    )
    if ($DEFAULT_BRANCH -ge "16.0") {
        $default["server"].Remove("longpolling-port")
    }
    return (ConvertTo-Json -Depth 100 $default)
}

function Build-DefaultConfig {
    $configExists = Test-Path -PathType Leaf $CONFIG_FILE
    if ($configExists) { throw "$CONFIG_FILE already exists" }
    Set-Content -Path $CONFIG_FILE -Value (Get-DefaultConfig)
}

function checkConfigFile {
    $configExists = Test-Path -PathType Leaf $CONFIG_FILE
    if (-Not $configExists) {
        throw "Need config file $CONFIG_FILE.`n`ntry Build-DefaultConfig"
    }
}

function loadConfig {
    checkConfigFile
    return (Get-Content -Path $CONFIG_FILE | ConvertFrom-Json -AsHashtable)
}

function buildConnectionString {
    param (
        [hashtable] $params
    )
    $lines = @()
    foreach ($p in $params.GetEnumerator()) {
        $lines += "$($p.Name)=$($p.Value)"
    }
    return ($lines -Join ";")
}

$typeAdded = $false

function pgQuery($server, $port, $dbname, $user, $pass, $sql) {
    if (-Not $typeAdded) {
        Add-Type -Path (Join-Path $PSScriptRoot "Npgsql.dll")
        $typeAdded = $true
    }
    $params = @{
        "Server"   = $server;
        "Port"     = $port;
        "User Id"  = $user;
    }
    if ($dbname -ne $null) { $params.Database = $dbname; }
    if ($pass -ne $null) { $params.Password = $pass; }
    if ($params.Server -eq $null) { $params.Server = "127.0.0.1" }
    if ($params.Port   -eq $null) { $params.Port   = 5432 }
    $connectionString = buildConnectionString $params
    $conn = [Npgsql.NpgsqlConnection]::new($connectionString)
    [void] $conn.Open()
    try {
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $sql
        $reader = $cmd.ExecuteReader()
        try {
            $table = [System.Data.DataTable]::new()
            $table.Load($reader)
            foreach ($r in $table.Rows) {
                $r
            }
        } finally {
            [void] $reader.Close()
        }
    } finally {
        [void] $conn.Close()
    }
}

function query($config, $sql) {
    return pgQuery `
      -server $config.db.server `
      -port   $config.db.port `
      -dbname $config.db.name `
      -user   $config.db.user `
      -pass   $config.db.pass `
      -sql    $sql
}

function queryWithRoot($config, $sql) {
    return pgQuery `
      -server $config.db.server `
      -port   $config.db.port `
      -user   $config.db.root `
      -sql    $sql
}

function queryExists($rows) {
    foreach ($r in $rows) {
        return $true
    }
    return $false
}

function databaseExists($config) {
    $sql = "select datname from pg_catalog.pg_database where datname = '$($config.db.name)'"
    $rows = queryWithRoot $config $sql
    return queryExists($rows)
}

function userExists($config) {
    $sql = "select usename from pg_catalog.pg_user where usename = '$($config.db.user)'"
    $rows = queryWithRoot $config $sql
    return queryExists($rows)
}

function tableExists($config, $table) {
    $sql = @(
        "select tablename from pg_catalog.pg_tables"
        "  where schemaname = 'public'"
        "    and tablename  = '$table'"
    ) -Join "`n"
    $rows = queryWithRoot $config $sql
    return queryExists($rows)
}

function addonInstalled($config, $module) {
    $sql = "select name from ir_module_module where name = '$module' and state = 'installed'"
    $rows = query $config $sql
    return queryExists($rows)
}

function dropDatabaseAndUser($config) {
    psql -U "$($config.db.root)" -c "drop database if exists $($config.db.name)"
    psql -U "$($config.db.root)" -c "drop user     if exists $($config.db.user)"
}

function createDatabaseAndUser($config) {
    if (-Not (databaseExists $config)) {
        psql -U "$($config.db.root)" -c "create database $($config.db.name)"
    }
    if (-Not (userExists $config)) {
        psql -U "$($config.db.root)" -c "create user $($config.db.user) with password '$($config.db.pass)'"
    }
    psql -U "$($config.db.root)" -c "alter database $($config.db.name) owner to $($config.db.user)"
}

function Remove-OdooDatabaseAndUser {
    param(
        [switch] $Force
    )
    if (-Not $Force) { throw "Need -Force do remove Odoo database" }
    dropDatabaseAndUser $(loadConfig)
}

function checkOut($source, $branch, $target) {
    if (Test-Path -PathType Container $target) { return }
    if ($branch -eq $null) {
        git clone --depth 1                  $source $target
    } else {
        git clone --depth 1 --branch $branch $source $target
    }
}

function checkOutParts($source, $branch, $target, $dirParts, $fileParts) {
    if (Test-Path -PathType Container $target) { return }
    if ($branch -eq $null) {
        git clone --depth 1 --filter blob:none                  --sparse $source $target
    } else {
        git clone --depth 1 --filter blob:none --branch $branch --sparse $source $target
    }
    Push-Location $target
    try {
        foreach ($p in $dirParts) {
            if ($p.StartsWith('./')) { $p = $p.SubString(1) }
            if (-Not $p.StartsWith('/')) { $p = "/$p" }
            git sparse-checkout add $p
        }
        foreach ($p in $fileParts) {
            if ($p.StartsWith('./')) { $p = $p.SubString(1) }
            if (-Not $p.StartsWith('/')) { $p = "/$p" }
            git sparse-checkout add $p
        }
    } finally {
        Pop-Location
    }
}

function initializeSources($config) {
    if ($config.odoo -ne $null) {
        checkOut `
            -source $config.odoo.source `
            -branch $config.odoo.branch `
            -target $PATH_ODOO
    }
    foreach ($addon in $config.addons.GetEnumerator()) {
        if ($addon.Name.StartsWith('_')) { continue }
        [void] (New-Item -Force -ItemType Directory $PATH_ADDONS)
        if ($addon.Value.parts.count -le 0) {
            checkOut `
              -source $addon.Value.source `
              -branch $addon.Value.branch `
              -target (Join-Path $PATH_ADDONS $addon.Name)
        } else {
            checkOutParts `
              -source $addon.Value.source `
              -branch $addon.Value.branch `
              -target (Join-Path $PATH_ADDONS $addon.Name) `
              -dirParts $addon.Value.parts `
              -fileParts $addon.Value.requirements
        }
    }
}

function Update-OdooServerSources {
    $config = (loadConfig)
    Push-Location $PATH_ODOO
    git pull
    Pop-Location

    foreach ($addon in $config.addons.GetEnumerator()) {
        Push-Location (Join-Path $PATH_ADDONS $addon.Name)
        git pull
        Pop-Location
    }
}

function removeIfExists($target) {
    if (-Not (Test-Path -PathType Container $target)) { return }
    if (-not (($target -eq $null) -or ($target -eq ""))) {
        Remove-Item -r -force $target
    }
}

function overridePackages($dict) {
    if ($dict.Count -gt 0) {
        foreach ($item in $dict.GetEnumerator()) {
            python -m pip install "$($item.Name)$($item.Value)"
        }
    }
}

function initializeVenv {
    if (Test-Path -PathType Container $PATH_VENV) { return }
    pyenv exec python -m venv "$PATH_VENV"
    . $PATH_VENV/Scripts/activate.ps1
    python -m ensurepip   --upgrade
    python -m pip install --upgrade pip
    python -m pip install    wheel                          # make wheel first priority requirement
    python -m pip install -e "$PATH_ODOO"                   # install Odoo source as package
    python -m pip install -r "$PATH_ODOO/requirements.txt"  # install standard Odoo requirements

    # Comfort error messages
    Write-Output "*************************************************************************"
    Write-Output "* Do not worry if there are errors in cryptography package installation *"
    Write-Output "* It's ok                                                               *"
    Write-Output "*************************************************************************"

    # Install requirements for each addons
    foreach ($addon in (Get-ChildItem $PATH_ADDONS)) {
        $reqs = $null
        if ($config.addons -ne $null) { $reqs = $config.addons[$addon.Name].requirements }
        foreach ($r in $reqs) {
            $path = Join-Path $addon.FullName $r
            python -m pip install -r $path
        }
    }

    # Install common requirements
    python -m pip install -r (Join-Path $PSScriptRoot "requirements.txt")

    # Install requirements for enterprise
    if ($config.addons.ContainsKey("enterprise")) {
        python -m pip install -r (Join-Path $PSScriptRoot "requirements_enterprise.txt")
    }

    # Install requirements if reporting-engine is used
    if ($config.addons.ContainsKey("reporting-engine")) {
        python -m pip install -r (Join-Path $PSScriptRoot "requirements_reporting_engine.txt")
    }

    # Install requirements for development
    python -m pip install -r (Join-Path $PSScriptRoot "requirements_develop.txt")

    # Install requirements for development
    python -m pip install -r (Join-Path $PSScriptRoot "requirements_develop.txt")

    # to override packages based on config
    $config = (loadConfig)

    # packages overriding by recipe
    $branch = $config['odoo']['branch']
    overridePackages $config['override-recipes'][$branch]

    # custom packages overriding
    overridePackages $config['override']
}

function isValidAddonPath($p) {
    # "addon path" is a path that has some valid "addon module path" inside
    if (-Not (Test-Path -PathType Container $p)) { return $false }
    $countDir = Get-ChildItem -Directory $p | Measure-Object | Select-Object -ExpandProperty Count
    return ($countDir -gt 0)
}

function isValidAddonModulePath($p) {
    # "addon module path" is a path that has "__manifest__".py inside.
    if (-Not (Test-Path -PathType Container $p)) { return $false }
    $countDir = Get-ChildItem -File -Filter __manifest__.py -Path $p | Measure-Object | Select-Object -ExpandProperty Count
    return ($countDir -gt 0)
}

function addIfValidAddon {
    # add each path in "paths" into output "list" if the path is a valid "addon path"
    param(
        [System.Collections.ArrayList] $list,
        [string[]] $paths
    )
    foreach ($p in $paths) {
        if (isValidAddonPath $p) {
            [void] $list.Add((Get-Item $p).FullName)
        }
    }
}

function getAllAddonPaths($config) {
    # Note from Odoo 14 Development Cookbook:
    #   "The value of the addons_path variable is expected to be a
    #   comma-separated list of directories. Relative paths are
    #   accepted, but they are relative to the current working directory
    #   and therefore should be avoided in the configuration file."

    $addons = [System.Collections.ArrayList]@()

    # adding odoo own addons path
    addIfValidAddon $addons "$PATH_ODOO/addons"

    # adding addon paths from json config
    foreach ($addon in (Get-ChildItem $PATH_ADDONS)) {
        $dirs = $null
        if ($config.addons -ne $null) { $dirs = $config.addons[$addon.Name].dirs }
        if ($dirs -eq $null) { $dirs = @(".") }
        foreach ($d in $dirs) {
            $path = Join-Path $addon.FullName $d
            addIfValidAddon $addons $path
        }
    }
    return $addons
}

function Get-AllAddons {
    return (getAllAddonPaths $(loadConfig)
            | Get-ChildItem -Directory
            | Where-Object { isValidAddonModulePath $_ }
            | Select-Object -ExpandProperty Name )
}

function getInstalledAddons($config){
    return query $config "select * from ir_module_module where state = 'installed'"
}

function Get-InstalledAddons {
    return (getInstalledAddons $(loadConfig) | Select-Object -ExpandProperty name)
}

function Get-InstallableAddons {
    $all = Get-AllAddons
    $exclusions = @("auth_ldap", "*l10n_*", "hw_*", "pos_blackbox_be", "sale_ebay")
    $excluded = $all | ? {
        foreach ($exc in $exclusions) {
            if ($_ -Like $exc) {
                $false
                return
            }
        }
        $true
    }
    $inclusions = @("l10n_th*")
    $included = $all | ? {
        foreach ($inc in $inclusions) {
            if ($_ -Like $inc) {
                $true
                return
            }
        }
        $false
    }
    $addons = ($excluded + $included) | sort | Get-Unique
    $installed = [System.Collections.Generic.HashSet[String]]@(Get-InstalledAddons)
    $addons = $addons | ? {-Not $installed.Contains($_)}
    return $addons
}

function Invoke-OdooBin {
    [CmdletBinding(PositionalBinding=$false)]
    param (
        [switch]
        $gevent,

        [string[]]
        $watch,

        [string[]]
        $addons,

        [string[]]
        $ext,

        [parameter(ValueFromRemainingArguments=$true)]
        $remaining
    )
    $python      = (Resolve-Path "$PATH_VENV/Scripts/python.exe").Path
    $odoo_bin    = (Resolve-Path "$PATH_ODOO/odoo-bin").Path
    $gevent_arg  = $gevent ? "gevent" : ""
    $all_addons  = getAllAddonPaths $(loadConfig)
    if (${Addons}.Length -gt 0) {
        $all_addons = $all_addons + $Addons
    }
    $arguments = @()
    if (-Not [string]::IsNullOrEmpty($gevent_arg)){
        $arguments += $gevent_arg
    }
    $arguments += "--addons-path=`"$($all_addons -join ',')`""
    $arguments += $remaining
    $watching_paths = getAllAddonPaths $(loadConfig) | Get-ChildItem | ? { $_.Name -in $watch }
    if ($watching_paths.Length -gt 0) {
        if ($ext.Length -eq 0) {
            $ext = @("py"; "csv"; "xls"; "xlsx"; "po"; "rst"; "html"; "css"; "js"; "ts"; "png"; "svg"; "jpg"; "ico")
            if ($remaining -notcontains '--dev=xml') {
                $ext += 'xml'
            }
        }
        $python = '"' + $python + '"'
        $odoo_bin = '"' + $odoo_bin + '"'
        if ('-u' -NotIn $arguments) {
            $watching_modules = ($watching_paths | select -ExpandProperty Name) -join ','
            $arguments += @("-u"; $watching_modules)
        }
        $exec = (@($python; $odoo_bin; $arguments) -join ' ')
        $nodemon_arguments = @( "-x"; "$($exec)";
                                "-e"; "$($ext -join ' ')" )
        foreach ($w in $watching_paths) {
            $nodemon_arguments += @("-w"; ('"' + $w.FullName + '"'))
        }
        $command = 'nodemon'
        $arguments = $nodemon_arguments
    }
    else {
        $command = $python
        $arguments = @($odoo_bin) + @($arguments)
    }
    &"$command" @arguments
}

function Test-Odoo {
    [CmdletBinding(PositionalBinding=$false)]
    param (
        [Parameter(Mandatory=$true,Position=0)]
        [string[]]
        $addons,

        [parameter(ValueFromRemainingArguments=$true)]
        $remaining
    )
    $targets = ($addons -join ',')

    # During a debug session, server log messages can creep in. Most of these are from the werkzeug module.
    # They can be silenced by adding the --log-handler=werkzeug:WARNING option to the Odoo command.
    # Another option is to lower the general log verbosity using --log-level=warn.
    if ($remaining -eq $null) { $remaining = @() }
    $logHandlerSpecified = $remaining | ? { $_.StartsWith('--log-handler') }
    if ($logHandlerSpecified.Count -eq 0) {
        $remaining += @('--log-handler=werkzeug:WARNING')
    }
    #
    Invoke-OdooBin -- `
        -u $targets `
        --test-enable `
        --log-level=test `
        --stop-after-init `
        @remaining
}

function initializeBaseAndSaveConfig($config) {
    $arguments = @()
    if ($config.server -ne $null) {
        $arguments += "--http-port=$($config.server['http-port'])"
        $longpollingPort = $config.server['longpolling-port']
        if (-not [string]::IsNullOrWhiteSpace($longpollingPort)) {
            $arguments += "--longpolling-port=$($longpollingPort)"
        }
    }
    $baseInstalled = (tableExists $config "ir_module_module") -And (addonInstalled $config "base")
    if (-Not $baseInstalled) {
        Invoke-OdooBin -- `
          --stop-after-init `
          -d $config.db.name `
          -r $config.db.user `
          -w $config.db.pass `
          -i base `
          @argumenst
    }
    Invoke-OdooBin -- `
        --stop-after-init `
        -d $config.db.name `
        -r $config.db.user `
        -w $config.db.pass `
        --data-dir $PATH_DATA `
        --save `
        @arguments
}

function Install-AllInstallableAddons {
    $addons = Get-InstallableAddons
    if ($addons.count -gt 0) {
        $installing = ($addons -join ',')
        Write-Output "Installing:`n  $installing"
        Invoke-OdooBin -- --stop-after-init -i "$($addons -join ',')"
    } else {
        Write-Output "All addons is already installed"
    }
}

function Initialize-OdooServer {
    param (
        [switch] $Reinitialize
    )
    $config = loadConfig

    # sources
    if ($Reinitialize) {
        removeIfExists $PATH_ODOO
        removeIfExists $PATH_ADDONS
    }
    initializeSources $config

    # venv
    if ($Reinitialize) {
        removeIfExists $PATH_VENV
    }
    initializeVenv

    # db
    if ($Reinitialize) { dropDatabaseAndUser $config }
    createDatabaseAndUser $config

    initializeBaseAndSaveConfig $config
}

function getDependencies($mpath) {
    $p = $mpath.Replace("\", "\\")
    return python -c "import os.path; print('\n'.join(eval(open(os.path.join('$p', '__manifest__.py')).read())['depends']))"
}

Export-ModuleMember `
  -Function @(
      "Get-DefaultConfig"
      "Build-DefaultConfig"
      "Remove-OdooDatabaseAndUser"
      "Initialize-OdooServer"
      "Update-OdooServerSources"
      "Get-AllAddons"
      "Get-InstalledAddons"
      "Get-InstallableAddons"
      "Install-AllInstallableAddons"
      "Invoke-OdooBin"
      "Test-Odoo"
      "Show-Dependencies"
      "Show-InternalDependencies"
      "Get-SosoAddons"
      "Get-InstallableSosoAddons"
      "Install-AllSosoAddons"
  )
