$venvActivate = "$PSScriptRoot/venv/Scripts/Activate.ps1"
if (Test-Path $venvActivate) {
    . $venvActivate
}
import-module  $PSScriptRoot/scripts/odoo-server.psm1 -Force
