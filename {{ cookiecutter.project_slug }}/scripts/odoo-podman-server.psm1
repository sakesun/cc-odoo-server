$IS_DOT_SOURCE = ($MyInvocation.InvocationName -eq '.' -or $MyInvocation.Line -eq '')
$POSTGRES_IMAGE = "postgres:13.11"
$ODOO_IMAGE = "odoo:16.0"
$POD_NAME = "odoo"
$ODOO_DB_NAME = "odoo"
$ODOO_DB_USER = "odoo"

function Remove-PodmanVolume {
    param (
        [string] $volume
    )
    podman volume exists $volume
    if ($?) {
        podman volume rm --force $volume
    }
}

function Ensure-PodmanVolume {
    param (
        [string] $volume
    )
    podman volume exists $volume
    if (! $?) {
        podman volume create $volume
    }
}

function Remove-PostgresAndOdooVolumes {
    Remove-PodmanVolume var-lib-postgresql-data
    Remove-PodmanVolume var-lib-odoo
    Remove-PodmanVolume mnt-extra-addons
}

function Ensure-PostgresAndOdooVolumes {
    Ensure-PodmanVolume var-lib-postgresql-data
    Ensure-PodmanVolume var-lib-odoo
    Ensure-PodmanVolume mnt-extra-addons
}

function Remove-OdooPod {
    podman pod exists $POD_NAME
    if ($?) {
        podman pod rm --force $POD_NAME
    }
}

function Ensure-OdooPod {
    podman pod exists $POD_NAME
    if (! $?) {
        podman pod create `
          --name $POD_NAME `
          --publish 5432:5432 `
          --publish 8069:8069 `
          --publish 8071:8071 `
          --publish 8072:8072
    }
}

function Run-OdooDbDetached {
    podman run `
      --name ${POD_NAME}-db `
      --pod $POD_NAME `
      --detach `
      --env POSTGRES_HOST_AUTH_METHOD=trust `
      --env POSTGRES_PORT=5432 `
      --volume var-lib-postgresql-data:/var/lib/postgresql/data `
      --rm `
      $POSTGRES_IMAGE
}

function Wait-OdooDb {
    while ($true) {
        podman run `
          --pod $POD_NAME `
          --env POSTGRES_HOST_AUTH_METHOD=trust `
          --env POSTGRES_PORT=5432 `
          --volume var-lib-postgresql-data:/var/lib/postgresql/data `
          --rm `
          $POSTGRES_IMAGE `
          pg_isready `
          --host=localhost `
          --port=5432 `
          --username=postgres
          if ($?) {
              break
              Start-Sleep -seconds 1
          }
    }
}

function Run-OdooDb {
    Ensure-OdooPod
    Run-OdooDbDetached
    Wait-OdooDb
}

function Create-OdooUserAndDatabase {
    podman run `
      --pod $POD_NAME `
      --volume var-lib-postgresql-data:/var/lib/postgresql/data `
      --rm `
      $POSTGRES_IMAGE
      psql `
      --host=localhost `
      --port=5432 `
      --username=postgres `
      --no-password `
      --command "create user odoo" `
      --command "alter user odoo with createdb" `
      --command "create database odoo" `
      --command "alter database odoo owner to odoo"
}

function Install-OdooBase {
    podman run `
      --pod $POD_NAME `
      --env DB_PORT_5432_TCP_ADDR=localhost `
      --env DB_PORT_5432_TCP_PORT=5432 `
      --env DB_ENV_POSTGRES_USER=odoo `
      --env DB_ENV_POSTGRES_PASSWORD= `
      --volume var-lib-odoo:/var/lib/odoo `
      --volume mnt-extra-addons:/mnt/extra-addons `
      --rm `
      $ODOO_IMAGE `
      odoo -d odoo -r odoo -i base --stop-after-init
}

function Run-OdooApp {
    podman run `
      --name ${POD_NAME}-app `
      --pod $POD_NAME `
      --env DB_PORT_5432_TCP_ADDR=localhost `
      --env DB_PORT_5432_TCP_PORT=5432 `
      --env DB_ENV_POSTGRES_USER=odoo `
      --env DB_ENV_POSTGRES_PASSWORD= `
      --volume var-lib-odoo:/var/lib/odoo `
      --volume mnt-extra-addons:/mnt/extra-addons `
      --rm `
      $ODOO_IMAGE `
      odoo
}


function RebuildAndRun-BaseApp {
    Remove-PostgresAndOdooVolumes
    Remove-OdooPod
    Ensure-PostgresAndOdooVolumes
    Ensure-OdooPod
    Run-OdooDb
    Create-OdooUserAndDatabase
    Install-OdooBase
    Run-OdooApp
}
