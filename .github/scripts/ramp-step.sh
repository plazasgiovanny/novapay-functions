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
# AZURE_SUBSCRIPTION_ID, AZURE_CLIENT_ID, AZURE_TENANT_ID, APP_ID, ROLE,
# OTHER_ROLE, TARGET_BACKEND, OTHER_BACKEND,
# DCE_LOGS_INGESTION_ENDPOINT (opcional),
# DCR_PESOACTUALIZADO_IMMUTABLE_ID (opcional).
#
# HALLAZGO REAL (2026-08-18, primera corrida real de este pipeline con
# tráfico insuficiente — run 32179489191, sesión de demo en vivo del
# pipeline a pedido del usuario): con tráfico orgánico bajo, un tramo al
# 5% de peso puede tardar mucho más de lo normal en juntar 50
# solicitudes reales en la instancia canary — el tramo llevaba ~1h
# corriendo (el mismo orden de magnitud que la vida de un token AAD)
# cuando el contador de observe_and_guard, que había llegado a 27/50,
# volvió a 0 y se quedó ahí. Causa raíz: las 6 llamadas a
# `az monitor app-insights query` de este archivo seguían el patrón
# `... 2>/dev/null || echo 0` — eso trata CUALQUIER fallo del comando
# (token expirado, throttling, red) exactamente igual que "la consulta
# corrió bien y el resultado real es cero". Consecuencia doble: (1) el
# step nunca cumple su condición de salida y se queda girando hasta el
# timeout-minutes:90 del job, un fallo lento y opaco en vez de uno
# rápido y claro; (2) peor, `failed`/`recent` (el guardrail de error
# rate) también quedan en 0 con el mismo fallo — si un error real
# ocurriera justo cuando el token expira, el guardrail quedaría ciego.
# Fix: ai_query() de abajo distingue "el comando falló" de "el conteo
# real es cero" (Kusto count() siempre devuelve una fila, así que un
# cero genuino nunca pasa por la rama de fallo) — al fallar,
# re-autentica vía OIDC directo (mismo mecanismo que azure/login@v2 por
# dentro, pero invocable a mitad de un step de bash) y reintenta una
# vez; si el reintento también falla, aborta con ::error:: explícito en
# vez de seguir reportando ceros. Distinto del hallazgo que cerró PR
# #16 (ese era el login expirando ENTRE tramos; este es el login
# expirando DENTRO de un mismo tramo cuando dura más de lo esperado).
set -euo pipefail

target_weight=$1
other_weight=$2
observe="${3:-true}"

azure_login_refresh () {
  local id_token
  id_token=$(curl -sS -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
    "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r '.value')
  az login --service-principal \
    -u "$AZURE_CLIENT_ID" \
    --tenant "$AZURE_TENANT_ID" \
    --federated-token "$id_token" \
    --output none
}

# Ejecuta una consulta de Application Insights distinguiendo "el
# comando az falló" de "el conteo real es cero" (ver HALLAZGO REAL
# arriba). Un solo reintento tras re-autenticar; si vuelve a fallar,
# aborta visiblemente en vez de reportar un cero fabricado.
ai_query () {
  local kql=$1
  local out err_file
  err_file=$(mktemp)
  if out=$(az monitor app-insights query --app "$APP_ID" --analytics-query "$kql" --query "tables[0].rows[0][0]" -o tsv 2>"$err_file"); then
    rm -f "$err_file"
    echo "${out:-0}"
    return 0
  fi
  echo "::warning::Consulta a Application Insights falló, reautenticando y reintentando: $(tail -1 "$err_file")"
  azure_login_refresh
  if out=$(az monitor app-insights query --app "$APP_ID" --analytics-query "$kql" --query "tables[0].rows[0][0]" -o tsv 2>"$err_file"); then
    rm -f "$err_file"
    echo "${out:-0}"
    return 0
  fi
  echo "::error::Consulta a Application Insights falló dos veces seguidas, incluso tras reautenticar — abortando el tramo en vez de asumir 0 solicitudes silenciosamente. Detalle: $(tail -1 "$err_file")"
  rm -f "$err_file"
  exit 1
}

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
  pct=$(ai_query "requests | where timestamp > ago(30d) | summarize total=count(), errores=countif(success == false) | extend errorRate = errores * 100.0 / total | extend presupuestoConsumido = errorRate / 0.03 * 100 | project presupuestoConsumido")
  echo "Consumo de error budget (ventana móvil 30 días): ${pct}%"
  if awk -v p="${pct:-0}" 'BEGIN { exit !(p+0 >= 80) }'; then
    echo "::error::Consumo de error budget >= 80% (${pct}%) — bloqueando el siguiente incremento de canary hasta que el presupuesto se recupere (ADR-07 §4.4). $ROLE se queda en el peso ya alcanzado, sin rollback."
    exit 1
  fi
}

# Ventana mínima antes de avanzar: al menos 15 minutos Y al menos 50
# solicitudes observadas (ambas, no una u otra). Aborta y hace rollback
# de tráfico (peso a 0) si el error rate supera 3% en cualquier chequeo.
#
# HALLAZGO REAL (auditoría de rigor arquitectónico, 2026-08-17): este
# guardrail solo miraba success == false (excepciones no controladas /
# 5xx) — ciego a una regresión de negocio real, la más probable en un
# despliegue de código: un bug que empiece a devolver 400 en masa para
# solicitudes que antes eran válidas. ValidatePayment maneja esos casos
# sin lanzar excepción, así que success queda en true sin importar el
# código HTTP (ver PLAN.md §3.5) — el guardrail nunca lo detectaba.
#
# Fix real: comparar la tasa de 400 del rol en rampa contra la del otro
# rol en la MISMA ventana, no un umbral absoluto — ambos reciben la
# misma mezcla real de tráfico (válido/inválido), así que una diferencia
# grande entre las dos tasas señala una regresión propia del código
# nuevo, no ruido de datos de cliente inválidos que ya existía antes del
# despliegue. Umbral: 10 puntos porcentuales de diferencia, con un piso
# mínimo de 3 solicitudes rechazadas para no disparar sobre muestras
# chicas.
observe_and_guard () {
  local step_start=$SECONDS
  while true; do
    sleep 120
    elapsed=$((SECONDS - step_start))
    total=$(ai_query "requests | where timestamp > ago($(( (elapsed + 59) / 60 ))m) and cloud_RoleName == '$ROLE' | count")
    failed=$(ai_query "requests | where timestamp > ago(5m) and cloud_RoleName == '$ROLE' and success == false | count")
    recent=$(ai_query "requests | where timestamp > ago(5m) and cloud_RoleName == '$ROLE' | count")
    rechazadas=$(ai_query "requests | where timestamp > ago(5m) and cloud_RoleName == '$ROLE' and resultCode == '400' | count")
    recent_otro=$(ai_query "requests | where timestamp > ago(5m) and cloud_RoleName == '$OTHER_ROLE' | count")
    rechazadas_otro=$(ai_query "requests | where timestamp > ago(5m) and cloud_RoleName == '$OTHER_ROLE' and resultCode == '400' | count")

    if [ "${recent:-0}" -gt 0 ]; then
      error_pct=$(( (failed * 100) / recent ))
      if [ "$error_pct" -gt 3 ]; then
        echo "::error::Error rate ${error_pct}% (>3%) en $ROLE — rollback de tráfico a 0% y abortando la rampa."
        set_weights 0 100
        exit 1
      fi
    fi

    if [ "${recent:-0}" -gt 0 ] && [ "${recent_otro:-0}" -gt 0 ] && [ "${rechazadas:-0}" -ge 3 ]; then
      tasa_rechazo=$(( (rechazadas * 100) / recent ))
      tasa_rechazo_otro=$(( (rechazadas_otro * 100) / recent_otro ))
      diff_rechazo=$((tasa_rechazo - tasa_rechazo_otro))
      if [ "$diff_rechazo" -gt 10 ]; then
        echo "::error::Tasa de rechazo (400) ${tasa_rechazo}% en $ROLE vs ${tasa_rechazo_otro}% en $OTHER_ROLE (misma ventana, misma mezcla de tráfico) — posible regresión de negocio en el código nuevo. Rollback de tráfico a 0% y abortando la rampa."
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
