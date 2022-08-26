$PATH_ROOT     = (Join-Path $PSScriptRoot "..")
$PATH_VENV     = (Join-Path $PATH_ROOT "venv-odoo")
$PATH_ODOO     = (Join-Path $PATH_ROOT "odoo")
$PATH_ADDONS   = (Join-Path $PATH_ROOT "addons")
$CONFIG_FILE   = (Join-Path $PATH_ROOT "odoo-server-config.json")

function Get-DefaultBranch($targetName) {
    return "15.0"
}

function checkOut($source, $branch, $target) {
    if (Test-Path $target -PathType Container) { return }
    if ($branch -eq $null) {
        $branch = Get-DefaultBranch -targetName (Split-Path -Leaf $target)
    }
    git clone --depth 1 --branch $branch $source $target
}

function Get-OdooServerSources($config) {
    if ($config.odoo -ne $null) {
        checkOut $config.odoo.source $config.odoo.branch $PATH_ODOO
    }
    foreach ($addon in $config.addons.GetEnumerator()) {
        [void](New-Item -Force -ItemType Directory $PATH_ADDONS)
        checkOut $addon.Value.source $addon.Value.branch (Join-Path $PATH_ADDONS $addon.Name)
    }
}

function localGitSource($path) {
    return "file://$($path.Replace('\', '/'))"
}

function checkConfigFile {
    $configExists = Test-Path $CONFIG_FILE -PathType Leaf
    if (! $configExists) {
        $branch = "15.0"
        $defaultContent = (
            [ordered]@{
                "odoo" = @{
                    "source" = localGitSource (Join-Path $PSScriptRoot ".." ".." "odoo-src" "odoo");
                    "branch" = $branch
                };
                "addons" = @{
                    "enterprise" = @{
                        "source" = localGitSource (Join-Path $PSScriptRoot ".." ".." "odoo-src" "enterprise");
                        "branch" = $branch
                    };
                    "design-themes" = @{
                        "source" = localGitSource (Join-Path $PSScriptRoot ".." ".." "odoo-src" "design-themes");
                        "branch" = $branch
                    }
                };
                "db" = @{
                    "root" = "postgres";
                    "name" = "odoo";
                    "user" = "user";
                    "pass" = "password"
                }
            }
            | ConvertTo-Json
        )
        [Console]::Error.WriteLine("Need $CONFIG_FILE")
        [Console]::Error.WriteLine("`nGenerate default content:`n")
        [Console]::Error.WriteLine("$defaultContent")
        $defaultContent | Out-File $CONFIG_FILE
    }
    return $configExists
}

function loadConfig {
    return (Get-Content -Path $CONFIG_FILE | ConvertFrom-Json -AsHashtable)
}

function Get-Test {
    if (checkConfigFile) {
        Get-OdooServerSources (loadConfig)
    } else {
    }
}

Export-ModuleMember `
  -Function @(
      "Get-Test",
      "Get-OdooServerSources"
  )
