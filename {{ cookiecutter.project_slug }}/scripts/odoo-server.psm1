# cookiecutter params
$CONFIG_FILE_NAME   = "{{ cookiecutter.project_slug }}.json"
$DB_NAME            = "{{ cookiecutter.db_name }}"
$DB_USER            = "{{ cookiecutter.db_user }}"
$DB_PASS            = "{{ cookiecutter.db_pass }}"

# global constants
$DEFAULT_VERSION  = "16.0"
$DEFAULT_BRANCH   = $DEFAULT_VERSION
$PATH_ROOT        = Join-Path $PSScriptRoot ".."
$PATH_VENV        = Join-Path $PATH_ROOT "venv"
$PATH_ODOO        = Join-Path $PATH_ROOT "odoo"
$PATH_ADDONS      = Join-Path $PATH_ROOT "addons"
$PATH_DATA        = Join-Path $PATH_ROOT "data"
$CONFIG_FILE      = Join-Path $PATH_ROOT $CONFIG_FILE_NAME
$ODOO_CONF        = Join-Path $PATH_ROOT "odoo.conf"
$DEMO_DATA        = $True

function localGitSource($path) {
    # relative path does not work. use absolute path only
    return "file://$($path.Replace('\', '/'))"
}

function Get-DefaultConfig {
    $branch = $DEFAULT_BRANCH
    $default = (
        [ordered]@{
            "db" = [ordered]@{
                "server" = "127.0.0.1";
                "port"   = $DB_PORT;
                "root"   = "postgres";
                "name"   = $DB_NAME;
                "user"   = $DB_USER;
                "pass"   = $DB_PASS;
            }
            "server" = [ordered]@{
                "http-port"        = 8069;
                "longpolling-port" = 8072;
            }
            "override-recipes" = [ordered]@{
                "15.0" = [ordered]@{
                    "werkzeug"     = "<2.0.0";
                    "urllib3"      = "==1.26.11";
                }
                "16.0" = [ordered]@{
                    "pyOpenSSL"    = "~=22.1";
                }
            }
            "override" = [ordered]@{}
            "odoo" = [ordered]@{
                "source" = "https://github.com/odoo/odoo.git";
                "branch" = $branch;
            }
            "addons" = [ordered]@{
                "enterprise" = [ordered]@{
                    "source" = "https://github.com/odoo/enterprise.git";
                    "branch" = $branch;
                    "dirs"   = @(".");
                }
                "design-themes" = [ordered]@{
                    "source" = "https://github.com/odoo/design-themes.git";
                    "branch" = $branch;
                    "dirs"   = @(".");
                }
                "l10n-thailand" = [ordered]@{
                    "source" = "https://github.com/OCA/l10n-thailand.git";
                    "parts"  = @("l10n_th_account_tax");
                    "branch" = "15.0";
                    "dirs"   = @(".");
                    "requirements" = @("requirements.txt");
                }
            }
        }
    )
    if ($DEFAULT_VERSION -ge "16.0") {
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
        "select tablename from pg_catalog.pg_tables";
        "  where schemaname = 'public'";
        "    and tablename  = '$table'";
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
    $DOWNLOAD_INSTEAD = $true
    if ($DOWNLOAD_INSTEAD -And $source.StartsWith("https://github.com/")) {
        try {
            downloadFromGithub $source $branch $target
            return
        } catch {}
    }
    # otherwise
    checkOutParts $source $branch $target $null $null
}

function downloadFromGithub ($source, $branch, $target) {
    if (Test-Path -PathType Container $target) { return }
    $b = [UriBuilder]::new($source)
    $b.Host = "codeload.github.com"
    $b.Path = $b.Path.TrimEnd(".git") + "/zip/refs/heads/$branch"
    $uri = $b.ToString()
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        Invoke-WebRequest -Uri $uri -OutFile $tmp
        $extracted = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
        [System.IO.Directory]::CreateDirectory($extracted)
        try {
            unzip -o $tmp -d $extracted
            $root = (Get-ChildItem $extracted | Select-Object -First 1)
            Move-Item $root/* $target
        } finally {
            Remove-Item -Recurse $extracted
        }
    } finally {
        Remove-Item -Path $tmp
    }
}

function checkOutParts($source, $branch, $target, $dirParts, $fileParts) {
    if (Test-Path -PathType Container $target) { return }
    mkdir $target | pushd
    try {
        git init
        git remote add origin $source
        if ($branch -eq $null) {
            git fetch --depth 1 origin master
        } else {
            git fetch --depth 1 origin $branch
        }
        $allParts = $dirParts + $fileParts  # sparse-checkout always add all root files, however
        if ($allParts.length -gt 0) {
            git sparse-checkout init --cone
            foreach ($p in $allParts) {
                git sparse-checkout add $p
            }
        }
        git checkout FETCH_HEAD
    } catch {
        throw
    } finally {
        popd
    }
}

function initializeSources ($config) {
    if (useOdooFromSource $config) {
        checkOut `
          -source $config.odoo.source `
          -branch $config.odoo.branch `
          -target $PATH_ODOO
    }
    [void] (New-Item -Force -ItemType Directory $PATH_ADDONS)
    if ($config.addons -ne $null) {
        foreach ($addon in $config.addons.GetEnumerator()) {
            if ($addon.Name.StartsWith('_')) { continue }
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
}

function downloadAndInstallOdooNightly ($config) {
    $version = $config.odoo?.version ?? $DEFAULT_VERSION
    $tag     = $config.odoo?.tag ?? "latest"
    $filename = "odoo_$version.$tag.tar.gz"
    $uri = "https://nightly.odoo.com/$version/nightly/src/$filename"
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        Invoke-WebRequest -Uri $uri -OutFile $tmp
        $extracted = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
        [System.IO.Directory]::CreateDirectory($extracted)
        try {
            tar xvzf $tmp -C $extracted
            $root = (Get-ChildItem $extracted | Select-Object -First 1)
            Push-Location $root
            python setup.py install
            Pop-Location
        } finally {
            Remove-Item -Recurse $extracted
        }
    } finally {
        Remove-Item -Path    $tmp
    }
}

function Update-OdooServerSources {
    $config = (loadConfig)
    Push-Location $PATH_ODOO
    git pull
    Pop-Location
    if ($config.addons -ne $null) {
        foreach ($addon in $config.addons.GetEnumerator()) {
            Push-Location (Join-Path $PATH_ADDONS $addon.Name)
            git pull
            Pop-Location
        }
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
            python -m pip uninstall -y "$($item.Name)"
            python -m pip install      "$($item.Name)$($item.Value)"
        }
    }
}

function useOdooFromSource ($config) {
    return $config.odoo?.source -ne $null
}

function useOdooNightlyInstall ($config) {
    return -Not (useOdooFromSource $config)
}

function initializeVenv ($config) {
    if (Test-Path -PathType Container $PATH_VENV) { return }
    python -m venv "$PATH_VENV"
    New-Item -ItemType file -Force `
      -Path  (Join-Path "$PATH_VENV" "Lib" "site-packages" "cc-odoo-server.pth") `
      -Value "../../../py"
    . $PATH_VENV/Scripts/activate.ps1
    python -m ensurepip   --upgrade
    python -m pip install --upgrade pip


    if (useOdooFromSource $config) {
        python -m pip install -e "$PATH_ODOO"                   # install Odoo source as package
        python -m pip install -r "$PATH_ODOO/requirements.txt"  # install standard Odoo requirements
    }

    if (useOdooNightlyInstall $config) {
        downloadAndInstallOdooNightly $config
    }

    # Comfort error messages
    Write-Host "*************************************************************************"
    Write-Host "* Do not worry if there are errors in cryptography package installation *"
    Write-Host "* It's ok                                                               *"
    Write-Host "*************************************************************************"

    # Install requirements for each addons
    foreach ($addon in (Get-ChildItem $PATH_ADDONS)) {
        $reqs = $null
        if ($config.addons -ne $null) { $reqs = $config.addons[$addon.Name].requirements }
        foreach ($r in $reqs) {
            $path = Join-Path $addon.FullName $r
            python -m pip install -r $path
        }
    }

    # Install setuptools and wheel as suggested in Odoo doc
    # https://www.odoo.com/documentation/16.0/administration/install/source.html#dependencies
    python -m pip install setuptools wheel

    # Install common requirements
    python -m pip install -r (Join-Path $PSScriptRoot "requirements.txt")

    # Install requirements for enterprise
    if ($config.addons -ne $null) {
        if ($config.addons.ContainsKey("enterprise")) {
            python -m pip install -r (Join-Path $PSScriptRoot "requirements_enterprise.txt")
        }
    }

    # Install requirements if reporting-engine is used
    if ($config.addons -ne $null) {
        if ($config.addons.ContainsKey("reporting-engine")) {
            python -m pip install -r (Join-Path $PSScriptRoot "requirements_reporting_engine.txt")
        }
    }

    # Install requirements for development
    python -m pip install -r (Join-Path $PSScriptRoot "requirements_develop.txt")

    # to override packages based on config
    $config = (loadConfig)

    # packages overriding by recipe
    $branch = $config.odoo?.branch
    $recipe = $config['override-recipes']?[$branch]
    if ($recipe -ne $null) { overridePackages $recipe }

    # custom packages overriding
    if ($config.override -ne $null) {
        overridePackages $config.override
    }
}

function isValidAddonPath($p) {
    # "addon path" is a path that has some valid "addon module path" inside
    if (-Not (Test-Path -PathType Container $p)) { return $false }
    $countDir = Get-ChildItem -Directory $p `
      | Where-Object { isValidAddonModulePath($_) } `
      | Measure-Object `
      | Select-Object -ExpandProperty Count
    return ($countDir -gt 0)
}

function isValidAddonModulePath($p) {
    # "addon module path" is a path that has "__manifest__".py inside.
    if (-Not (Test-Path -PathType Container $p)) { return $false }
    $countDir = Get-ChildItem -File -Filter __manifest__.py -Path $p `
      | Measure-Object `
      | Select-Object -ExpandProperty Count
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

    # adding custom addons path
    addIfValidAddon $addons $PATH_CUSTOM_ADDONS

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
    $exclusions = @("auth_ldap"; "*l10n_*"; "hw_*"; "pos_blackbox_be"; "sale_ebay")
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
    $odoo_bin    = (Resolve-Path "$PATH_VENV/Scripts/odoo").Path
    $gevent_arg  = $gevent ? "gevent" : ""
    $all_addons  = getAllAddonPaths $(loadConfig)
    if (${addons}.Length -gt 0) {
        $all_addons = $all_addons + $addons
    }
    $arguments = @("-c"; $ODOO_CONF)
    if (-Not [string]::IsNullOrEmpty($gevent_arg)){
        $arguments += $gevent_arg
    }
    $arguments += "--addons-path=$($all_addons -join ',')"
    $arguments += $remaining
    $watching_paths = getAllAddonPaths $(loadConfig) | Get-ChildItem | ? { $_.Name -in $watch }
    if ($watching_paths.Length -gt 0) {
        if ($ext.Length -eq 0) {
            $ext = @("py"; "csv"; "xls"; "xlsx"; "po"; "rst"; "html"; "css"; "js"; "ts"; "png"; "svg"; "jpg"; "ico")
            if ($remaining -notcontains '--dev=xml') {
                $ext += 'xml'
            }
        }
        if ('-u' -NotIn $arguments) {
            $watching_modules = ($watching_paths | select -ExpandProperty Name) -join ','
            $arguments += @("-u"; $watching_modules)
        }
        $exec = (@($python; $odoo_bin; $arguments) -join ' ')
        $nodemon_arguments = @( "-x"; "$($exec)";
                                "-e"; "$($ext -join ' ')" )
        foreach ($w in $watching_paths) {
            $nodemon_arguments += @("-w"; ($w.FullName))
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

function ensureRequiredToolsAreInstalled {
    if ((Get-Command -Name "wkhtmltopdf" -ErrorAction Ignore) -eq $null) {
        scoop install wkhtmltopdf
    }
    if ((Get-Command -Name "xmllint" -ErrorAction Ignore) -eq $null) {
        scoop install xmllint
    }
}

function initializeBaseAndSaveConfig($config) {
    ensureRequiredToolsAreInstalled
    $arguments = @()
    $all_addons  = getAllAddonPaths $config

    # add configurations that will goes to odoo.conf
    $arguments += @(
        "--data-dir="    + $PATH_DATA;
        "--addons-path=" + $($all_addons -join ',');
    )
    $arguments += @(
        "--database="    + $config.db.name;
        "--db_user="     + $config.db.user;
        "--db_password=" + $config.db.pass;
    )
    if ($config.db.port) {
        $arguments += "--db_port=" + $config.db.port
    }
    if ($config.server -ne $null) {
        $arguments += "--http-port=$($config.server['http-port'])"
        $longpollingPort = $config.server['longpolling-port']
        if (-not [string]::IsNullOrWhiteSpace($longpollingPort)) {
            $arguments += "--longpolling-port=$($longpollingPort)"
        }
    }
    if (-Not $DEMO_DATA) {
        $arguments += "--without-demo=all"
    }
    $baseInstalled = (tableExists $config "ir_module_module") -And (addonInstalled $config "base")
    if (-Not $baseInstalled) {
        Invoke-OdooBin -- @arguments --save --stop-after-init --init=base
    } else {
        Invoke-OdooBin               --save --stop-after-init --init=base
    }
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
    initializeVenv $config

    # db
    if ($Reinitialize) { dropDatabaseAndUser $config }
    createDatabaseAndUser $config

    # data dir and odoo.conf
    if ($Reinitialize) {
        removeIfExists $PATH_DATA
        if (Test-Path $ODOO_CONF) { Remove-Item $ODOO_CONF }
    }

    initializeBaseAndSaveConfig $config
}

function getDependencies($mpath) {
    $p = $mpath.Replace("\", "\\")
    return python -c "import os.path; print('\n'.join(eval(open(os.path.join('$p', '__manifest__.py')).read())['depends']))"
}

Export-ModuleMember `
  -Function @(
      "Get-DefaultConfig";
      "Build-DefaultConfig";
      "Remove-OdooDatabaseAndUser";
      "Initialize-OdooServer";
      "Update-OdooServerSources";
      "Get-AllAddons";
      "Get-InstalledAddons";
      "Get-InstallableAddons";
      "Install-AllInstallableAddons";
      "Invoke-OdooBin";
      "Test-Odoo";
  )
