#!/usr/bin/env bash
# .github/scripts/ramp-step.sh <target_weight> <other_weight> [observe=true]
#
# Un tramo de la rampa canary (backend pool ponderado de APIM, ver
# ADR-03/ADR-07 U4 en novapay-iac-terraform). Vive en un script propio
# (no inline en cd.yml) porque cada tramo real corre en su propio step
# de GitHub Actions, cada uno precedido por su propio azure/login.
#
# HALLAZGO REAL (2026-08-17, primer ciclo de rampa real que corrió lo
# suficiente para exponerlo): con los 3 tramos como un único step de
# bash y un solo azure/login al inicio del job, el ciclo completo tomó
# ~54 min reales (sleep 120 en el loop de espera de cada tramo) —
# superó la vida del token OIDC obtenido al inicio, y az cli no puede
# renovar la assertion sola a mitad de un step (AADSTS700024, "Client
# assertion is not within its valid time range"). El run 32005137531
# quedó con el pool parado en 25%/75% sin rollback (ese fallo no pasa
# por la rama del guardrail de error rate). Partir en 3 steps, cada uno
# con su propio login, evita el problema de raíz en vez de reintentar.
#
# Variables de entorno esperadas (ya presentes como env de job/step en
# cd.yml o exportadas a $GITHUB_ENV por el step "Preparar variables de
# la rampa"): RESOURCE_GROUP, APIM_NAME, POOL_NAME, API_VERSION,
# AZURE_SUBSCRIPTION_ID, APP_ID, ROLE, OTHER_ROLE, TARGET_BACKEND,
# OTHER_BACKEND, DCE_LOGS_INGESTION_ENDPOINT (opcional),
# DCR_PESOACTUALIZADO_IMMUTABLE_ID (opcional).
set -euo pipefail

target_weight=$1
other_weight=$2
observe="${3:-true}"

emit_peso_actualizado () {
  local instance=$1
  local peso=$2
  if [ -z "${DCE_LOGS_INGESTION_ENDPOINT:-}" ] || [ -z "${DCR_PESOACTUALIZADO_IMMUTABLE_ID:-}" ]; then
    return 0
  fi
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  az rest --resource "https://monitor.azure.com" --method post \
    --uri "${DCE_LOGS_INGESTION_ENDPOINT}/dataCollectionRules/${DCR_PESOACTUALIZADO_IMMUTABLE_ID}/streams/Custom-PesoActualizado?api-version=2023-01-01" \
    --headers "Content-Type=application/json" \
    --body "[{\"TimeGenerated\":\"$ts\",\"sourceInstance\":\"$instance\",\"pesoNuevo\":$peso}]" \
    || echo "::warning::No se pudo emitir el evento PesoActualizado para $instance=$peso (no bloqueante, ver ADR-07 U4)."
}

set_weights () {
  local w1=$1
  local w2=$2
  az rest --method patch \
    --uri "https://management.azure.com/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.ApiManagement/service/$APIM_NAME/backends/$POOL_NAME?api-version=$API_VERSION" \
    --body "{\"properties\":{\"pool\":{\"services\":[{\"id\":\"/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.ApiManagement/service/$APIM_NAME/backends/$TARGET_BACKEND\",\"weight\":$w1},{\"id\":\"/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.ApiManagement/service/$APIM_NAME/backends/$OTHER_BACKEND\",\"weight\":$w2}]}}}"
  emit_peso_actualizado "$ROLE" "$w1"
  emit_peso_actualizado "$OTHER_ROLE" "$w2"
}

# ADR-07 §4.4: no se incrementa el peso mientras el consumo de error
# budget (ventana móvil de 30 días) esté en 80% o más — distinto del
# guardrail de error rate agudo de observe_and_guard (rollback
# inmediato); este solo bloquea el SIGUIENTE incremento, sin rollback.
check_burn_rate_not_blocking () {
  local pct
  pct=$(az monitor app-insights query --app "$APP_ID" \
    --analytics-query "requests | where timestamp > ago(30d) | summarize total=count(), errores=countif(success == false) | extend errorRate = errores * 100.0 / total | extend presupuestoConsumido = errorRate / 0.03 * 100 | project presupuestoConsumido" \
    --query "tables[0].rows[0][0]" -o tsv 2>/dev/null || echo 0)
  echo "Consumo de error budget (ventana móvil 30 días): ${pct}%"
  if awk -v p="${pct:-0}" 'BEGIN { exit !(p+0 >= 80) }'; then
    echo "::error::Consumo de error budget >= 80% (${pct}%) — bloqueando el siguiente incremento de canary hasta que el presupuesto se recupere (ADR-07 §4.4). $ROLE se queda en el peso ya alcanzado, sin rollback."
    exit 1
  fi
}

# Ventana mínima antes de avanzar: al menos 15 minutos Y al menos 50
# solicitudes observadas (ambas, no una u otra). Aborta y hace rollback
# de tráfico (peso a 0) si el error rate supera 3% en cualquier chequeo.
observe_and_guard () {
  local step_start=$SECONDS
  while true; do
    sleep 120
    elapsed=$((SECONDS - step_start))
    total=$(az monitor app-insights query --app "$APP_ID" \
      --analytics-query "requests | where timestamp > ago($(( (elapsed + 59) / 60 ))m) and cloud_RoleName == '$ROLE' | count" \
      --query "tables[0].rows[0][0]" -o tsv 2>/dev/null || echo 0)
    failed=$(az monitor app-insights query --app "$APP_ID" \
      --analytics-query "requests | where timestamp > ago(5m) and cloud_RoleName == '$ROLE' and success == false | count" \
      --query "tables[0].rows[0][0]" -o tsv 2>/dev/null || echo 0)
    recent=$(az monitor app-insights query --app "$APP_ID" \
      --analytics-query "requests | where timestamp > ago(5m) and cloud_RoleName == '$ROLE' | count" \
      --query "tables[0].rows[0][0]" -o tsv 2>/dev/null || echo 0)

    if [ "${recent:-0}" -gt 0 ]; then
      error_pct=$(( (failed * 100) / recent ))
      if [ "$error_pct" -gt 3 ]; then
        echo "::error::Error rate ${error_pct}% (>3%) en $ROLE — rollback de tráfico a 0% y abortando la rampa."
        set_weights 0 100
        exit 1
      fi
    fi

    if [ "$elapsed" -ge 900 ] && [ "${total:-0}" -ge 50 ]; then
      echo "Ventana de observación cumplida: ${elapsed}s, ${total} solicitudes."
      return 0
    fi
    echo "Esperando ventana de observación: ${elapsed}s / 900s, ${total:-0} / 50 solicitudes."
  done
}

check_burn_rate_not_blocking
echo "Rampa a ${target_weight}%"
set_weights "$target_weight" "$other_weight"

if [ "$observe" = "true" ]; then
  observe_and_guard
else
  echo "Promoción completa: $ROLE al ${target_weight}%."
fi
