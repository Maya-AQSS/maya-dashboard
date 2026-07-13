#!/bin/bash
# maya_dashboard backend — entrypoint de PRODUCCIÓN.
#
# Distinto al entrypoint dev (no hace `composer install` ni `migrate`).
# El rol se determina por:
#   1) la variable de entorno CONTAINER_ROLE si está definida
#   2) el primer argumento posicional (CMD del Dockerfile)
#
# Roles soportados: api | worker | scheduler | reverb
#
# Reglas:
# - NO ejecutar composer en runtime (vendor viene de la imagen).
# - NO ejecutar migrate aquí (Job helm hook pre-upgrade).
# - Recachear config/route por si las env cambian entre releases.
# - Logs a stdout/stderr.
set -euo pipefail

ROLE="${CONTAINER_ROLE:-${1:-api}}"

cd /var/www/html

# ─── Secretos vía Vault Agent Injector (si el sidecar/init los inyectó) ───────
# El Vault Agent escribe /vault/secrets/config con líneas `export VAR="..."`.
# Lo cargamos ANTES de cachear config para que artisan vea las credenciales
# (APP_KEY, DB_PASSWORD, LOG_MGMT_DB_PASSWORD, KEYCLOAK_CLIENT_SECRET, ...). Sin
# fichero (dev / Secret k8s clásico), este bloque es un no-op y la env llega por
# envFrom.
if [ -f /vault/secrets/config ]; then
    set -a
    . /vault/secrets/config
    set +a
fi

# Asegurar que los dirs writable existan (en K3s vienen de emptyDir).
mkdir -p \
    storage/framework/cache/data \
    storage/framework/sessions \
    storage/framework/views \
    storage/logs \
    bootstrap/cache

# Limpiar y regenerar caches por release. Si Laravel falla aquí, queremos
# saberlo en el arranque del pod (probes en Failed → reinicio controlado).
# Mantenemos `|| true` (el clear sobre un cache ausente no es error real) pero
# NO redirigimos stderr, para que cualquier fallo real (APP_KEY, conexión, etc.)
# aparezca en los logs del pod.
php artisan config:clear  >/dev/null || true
php artisan route:clear   >/dev/null || true
php artisan view:clear    >/dev/null || true
php artisan event:clear   >/dev/null || true

php artisan config:cache
# `route:cache` aborta si hay closures en las rutas (no bloqueante).
# Capturamos stderr a stdout para visibilidad, pero permitimos fallo controlado.
php artisan route:cache >/dev/null 2>&1 || echo "[entrypoint] route:cache skipped (closures present)"
php artisan event:cache >/dev/null 2>&1 || echo "[entrypoint] event:cache skipped"

case "${ROLE}" in
    api)
        echo "[entrypoint] role=api → supervisord (nginx + php-fpm)"
        exec /usr/bin/supervisord -c /etc/supervisor/conf.d/api.conf
        ;;
    worker)
        echo "[entrypoint] role=worker → notifications:consume"
        exec php artisan notifications:consume --no-interaction
        ;;
    scheduler)
        echo "[entrypoint] role=scheduler → schedule:work"
        exec php artisan schedule:work --no-interaction
        ;;
    reverb)
        echo "[entrypoint] role=reverb → reverb:start :8080"
        exec php artisan reverb:start --host=0.0.0.0 --port=8080
        ;;
    sh|bash)
        exec "$@"
        ;;
    *)
        # Cualquier otro CMD se ejecuta tal cual (debug ad-hoc).
        exec "$@"
        ;;
esac
