$DEFAULT_BRANCH = "15.0"
$PATH_ROOT      = (Join-Path $PSScriptRoot "..")
$PATH_VENV      = (Join-Path $PATH_ROOT "venv")
$PATH_ODOO      = (Join-Path $PATH_ROOT "odoo")
$PATH_ADDONS    = (Join-Path $PATH_ROOT "addons")
$CONFIG_FILE    = (Join-Path $PATH_ROOT "odoo-server-config.json")

function Get-DefaultBranch($targetName) {
    return $DEFAULT_BRANCH
}

function loadConfig {
    return (Get-Content -Path $CONFIG_FILE | ConvertFrom-Json -AsHashtable)
}

function localGitSource($path) {
    return "file://$($path.Replace('\', '/'))"
}

function checkConfigFile {
    $configExists = Test-Path $CONFIG_FILE -PathType Leaf
    if (! $configExists) {
        $branch = $DEFAULT_BRANCH
        $defaultContent = (
            ConvertTo-Json -Depth 100 (
                [ordered]@{
                    "odoo" = @{
                        "source" = localGitSource (Join-Path $PSScriptRoot ".." ".." "odoo-src" "odoo");
                        "branch" = $branch
                    };
                    "addons" = @{
                        "enterprise" = @{
                            "source" = localGitSource (Join-Path $PSScriptRoot ".." ".." "odoo-src" "enterprise");
                            "branch" = $branch;
                            "dirs"   = @(".");
                        };
                        "design-themes" = @{
                            "source" = localGitSource (Join-Path $PSScriptRoot ".." ".." "odoo-src" "design-themes");
                            "branch" = $branch;
                            "dirs"   = @(".");
                        }
                    };
                    "db" = @{
                        "root" = "postgres";
                        "name" = "odoo";
                        "user" = "user";
                        "pass" = "password"
                    };
                    "server" = @{
                        "http-port"        = 8069;
                        "longpolling-port" = 8072;
                    }
                }
            )
        )
        [Console]::Error.WriteLine("Need $CONFIG_FILE")
        [Console]::Error.WriteLine("`nGenerate default content:`n")
        [Console]::Error.WriteLine("$defaultContent")
        $defaultContent | Out-File $CONFIG_FILE
    }
    return $configExists
}

function checkOut($source, $branch, $target) {
    if (Test-Path $target -PathType Container) { return }
    if ($branch -eq $null) {
        $branch = Get-DefaultBranch -targetName (Split-Path -Leaf $target)
    }
    git clone --depth 1 --branch $branch $source $target
}

function Initialize-OdooServerSources() {
    $config = (loadConfig)
    if ($config.odoo -ne $null) {
        checkOut $config.odoo.source $config.odoo.branch $PATH_ODOO
    }
    foreach ($addon in $config.addons.GetEnumerator()) {
        [void](New-Item -Force -ItemType Directory $PATH_ADDONS)
        checkOut $addon.Value.source $addon.Value.branch (Join-Path $PATH_ADDONS $addon.Name)
    }
}

function isValidAddonPath($p) {
    if (! (Test-Path $p)) { return $false }
    $countDir = (Get-ChildItem -Directory $p | Measure-Object | Select-Object -ExpandProperty Count)
    return ($countDir -gt 0)
}

function isValidAddonModulePath($p) {
    if (-Not (Test-Path $p)) { return $false }
    $countDir = (Get-ChildItem -File -Filter __manifest__.py -Path $p | Measure-Object | Select-Object -ExpandProperty Count)
    return ($countDir -gt 0)
}

function addIfValidAddon {
    param(
        [System.Collections.ArrayList] $list,
        [string[]] $paths
    )
    ForEach ($p in $paths) {
        if (isValidAddonPath $p) {
            [void]$list.Add((Get-Item $p).FullName)
        }
    }
}

function Get-AllAddonPaths {
    $addons = [System.Collections.ArrayList]@()
    addIfValidAddon $addons "$PATH_ODOO/addons"
    $config = (loadConfig)
    foreach ($addon in (Get-ChildItem -Directory $PATH_ADDONS)) {
        $dirs = $null
        if ($config.addons -ne $null) { $dirs = $config.addons[$addon.Name].dirs }
        if ($dirs -eq $null) { $dirs = @(".") }
        foreach ($d in $dirs) {
            $path = (Join-Path $addon.FullName $d)
            addIfValidAddon $addons $path
        }
    }
    return $addons
}

function Get-AllAddons {
    return (Get-AllAddonPaths
            | Get-ChildItem -Directory
            | Where-Object { isValidAddonModulePath $_.FullName }
            | Select-Object -ExpandProperty Name )
}

function Get-Addons {
    $all = (Get-AllAddonPaths | gci -Directory | select -ExpandProperty Name )
    $exclusions = @("auth_ldap", "*l10n_*")
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
    return $addons
}

function Initialize-OdooServerVenv {
    pyenv exec python -m venv "$PATH_VENV"
    . $PATH_VENV/Scripts/activate.ps1
    python -m ensurepip   --upgrade
    python -m pip install --upgrade pip
    python -m pip install -e "$PATH_ODOO"
    python -m pip install -r "$PATH_ODOO/requirements.txt"
    python -m pip install    psycopg2-binary   # psocopg2 does not work on Windows
    # python -m pip uninstall  Werkzeug --yes    # Werkzeug 2 does not work on Windows
    # python -m pip install    Werkzeug==1.0.1   #   use 1.0.1 instead
    python -m pip install    pdfminer.six
    python -m pip install    ipython
    python -m pip install    ipdb
    python -m pip install    watchdog
    python -m pip install    odoorpc
    # python -m pip uninstall  PyPDF2
    # python -m pip install    PyPDF2==1.28.4
    #
    # for enterprise
    python -m pip install    dbfread
    python -m pip install    google_auth
    python -m pip install    dbfread
    python -m pip install    dbfread
    python -m pip install    dbfread
    python -m pip install    phonenumbers
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
    $gevent_arg  = ($gevent) ? "gevent" : ""
    $all_addons  = Get-AllAddonPaths
    if (${Addons}.Length -gt 0) {
        $all_addons = $all_addons + $Addons
    }
    $arguments = @()
    if (-Not [string]::IsNullOrEmpty($gevent_arg)){
        $arguments += $gevent_arg
    }
    $arguments += "--addons-path=`"$($all_addons -join ',')`""
    $arguments += $remaining
    $watching_paths = (Get-AllAddonPaths | Get-ChildItem | ? { $_.Name -in $watch })
    if ($watching_paths.Length -gt 0) {
        if ($ext.Length -eq 0) {
            $ext = @("py"; "csv"; "xml"; "xls"; "xlsx"; "po"; "rst"; "html"; "css"; "js"; "ts"; "png"; "svg"; "jpg"; "ico")
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
        ForEach($w in $watching_paths) {
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

function Initialize-OdooServerConfig {
    $config = (loadConfig)
    $arguments = @()
    if ($config.server -ne $null) {
        $arguments += "--http-port=$($config.server['http-port'])"
        $arguments += "--longpolling-port=$($config.server['longpolling-port'])"
    }
    Invoke-OdooBin -- `
      --stop-after-init `
      -d $config.db.name `
      -r $config.db.user `
      -w $config.db.pass `
      -i base `
      @argumenst
    Invoke-OdooBin -- `
      --stop-after-init `
      -d $config.db.name `
      -r $config.db.user `
      -w $config.db.pass `
      --save `
      @arguments
}

function Initialize-OdooServer {
    Initialize-OdooServerSources
    Initialize-OdooServerVenv
    Initialize-OdooServerConfig
}

function Remove-RecursiveForce($target) {
    if (-not (($target -eq $null) -or ($target -eq ""))) {
        rm -r -force $target
    }
}

function Reset-OdooServer {
    Remove-RecursiveForce $PATH_VENV
    Remove-RecursiveForce $PATH_ODOO
    Remove-RecursiveForce $PATH_ADDONS
    $config = (loadConfig)
    psql -U $config.db.root -c "drop   database $($config.db.name)"
    psql -U $config.db.root -c "create database $($config.db.name)"
    psql -U $config.db.root -c "alter  database $($config.db.name) owner to $($config.db.user)"
}

function Install-AllAddons {
    $addons = (Get-Addons)
    Invoke-OdooBin -- --stop-after-init -i "$($addons -join ',')"
}

Export-ModuleMember `
  -Function @(
      "Get-DefaultBranch",
      "Initialize-OdooServerSources",
      "Get-AllAddonPaths",
      "Get-AllAddons",
      "New-OdooServerVenv",
      "Invoke-OdooBin",
      "Test-Odoo",
      "Initialize-OdooServerVenv",
      "Initialize-OdooServerConfig",
      "Initialize-OdooServer",
      "Reset-OdooServer",
      "Install-AllAddons"
  )
