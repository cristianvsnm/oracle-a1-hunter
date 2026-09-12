#!/usr/bin/env bash
# ============================================================
# Oracle Cloud A1 Flex Hunter - GitHub Actions
# Comando construido 100% con flags explícitos (sin --from-json)
# ============================================================

set -u

TENANCY_ID="${OCI_TENANCY_OCID:-}"
INTERVAL_SECONDS=120
LOG_FILE="./hunter.log"

log() {
  echo "$@" | tee -a "$LOG_FILE"
}

log ""
log "============================================"
log " Oracle Cloud A1 Flex Hunter"
log " Minecraft Server"
log "============================================"
log ""
log "Region:       ${OCI_REGION:-desconocida}"
log "Shape:        ${OCI_SHAPE:-VM.Standard.A1.Flex}"
log "OCPU:         ${OCI_OCPUS:-2}  |  RAM: ${OCI_MEMORY_GB:-12} GB  |  Disco: ${OCI_BOOT_VOLUME_GB:-50} GB"
log "Reintento:    cada ${INTERVAL_SECONDS}s"
log ""

# ------------------------------------------------------------
# Comprobaciones iniciales
# ------------------------------------------------------------
if ! command -v oci >/dev/null 2>&1; then
  log "ERROR: OCI CLI no está disponible."
  exit 1
fi

if [ -z "$TENANCY_ID" ]; then
  log "ERROR: OCI_TENANCY_OCID no está definido."
  exit 1
fi

if [ -z "${OCI_SUBNET_ID:-}" ]; then
  log "ERROR: OCI_SUBNET_ID no está definido."
  exit 1
fi

# ------------------------------------------------------------
# Bucle principal
# ------------------------------------------------------------
ATTEMPT=0

while true; do
  ATTEMPT=$((ATTEMPT + 1))

  log ""
  log "--------------------------------------------"
  log "Intento #$ATTEMPT - $(date '+%Y-%m-%d %H:%M:%S')"
  log "--------------------------------------------"

  # ----------------------------------------------------------
  # ¿Ya existe una instancia?
  # ----------------------------------------------------------
  log "Comprobando instancias existentes..."

  EXISTING=$(oci compute instance list \
      --compartment-id "$TENANCY_ID" \
      --output json 2>&1)
  RC=$?

  if [ $RC -eq 0 ]; then
    COUNT=$(echo "$EXISTING" | python -c \
      "import json,sys; d=json.load(sys.stdin); print(len(d.get('data',[])))" 2>/dev/null || echo "0")

    if [ "$COUNT" -gt 0 ]; then
      log ""
      log "Ya existe al menos una instancia. Deteniendo el Hunter."
      echo "$EXISTING" | python -c "
import json,sys
d = json.load(sys.stdin)
for i in d['data']:
    print('Nombre:', i.get('display-name'))
    print('OCID:  ', i.get('id'))
    print('Estado:', i.get('lifecycle-state'))
    print()
" 2>/dev/null | tee -a "$LOG_FILE"
      exit 0
    fi

    log "No hay instancias existentes."
  else
    log "No se pudo consultar instancias:"
    log "$EXISTING"
  fi

  # ----------------------------------------------------------
  # Intentar crear la instancia (100% flags explícitos)
  # ----------------------------------------------------------
  log ""
  log "Intentando crear ${OCI_SHAPE:-VM.Standard.A1.Flex} ${OCI_OCPUS:-2} OCPU / ${OCI_MEMORY_GB:-12} GB..."

  OUTPUT=$(oci compute instance launch \
      --compartment-id "$OCI_COMPARTMENT_ID" \
      --availability-domain "$OCI_AD" \
      --shape "$OCI_SHAPE" \
      --shape-config "{\"ocpus\": ${OCI_OCPUS}, \"memoryInGBs\": ${OCI_MEMORY_GB}}" \
      --subnet-id "$OCI_SUBNET_ID" \
      --image-id "$OCI_IMAGE_ID" \
      --boot-volume-size-in-gbs "${OCI_BOOT_VOLUME_GB:-50}" \
      --assign-public-ip true \
      --display-name "${OCI_DISPLAY_NAME:-minecraft-server}" \
      --metadata "{\"ssh_authorized_keys\": \"${OCI_SSH_KEY}\"}" \
      --output json 2>&1)
  RC=$?

  if [ $RC -eq 0 ]; then
    log ""
    log "============================================"
    log " INSTANCIA CREADA CORRECTAMENTE"
    log "============================================"
    log "$OUTPUT"

    echo "$OUTPUT" > resultado.json

    log ""
    log "Respuesta guardada en resultado.json"
    exit 0
  fi

  # ----------------------------------------------------------
  # Interpretar el error
  # ----------------------------------------------------------
  log "Oracle devolvió un error:"
  log "$OUTPUT"

  if echo "$OUTPUT" | grep -qiE "Out of host capacity|Out of capacity|OutOfHostCapacity"; then
    log ""
    log "SIN CAPACIDAD PARA A1 FLEX. Esperando ${INTERVAL_SECONDS}s..."
    sleep "$INTERVAL_SECONDS"
    continue
  fi

  if echo "$OUTPUT" | grep -qiE "TooManyRequests|429"; then
    log ""
    log "Rate limit (429). Esperando 5 minutos..."
    sleep 300
    continue
  fi

  if echo "$OUTPUT" | grep -qE "NotAuthenticated|NotAuthorized|401|403"; then
    log ""
    log "ERROR DE AUTENTICACIÓN/AUTORIZACIÓN. Deteniendo."
    exit 1
  fi

  # Errores de configuración: abortar para no entrar en bucle
  if echo "$OUTPUT" | grep -qE "Usage: oci|Missing option|Unknown option|Invalid value for|CannotParseRequest"; then
    log ""
    log "ERROR DE CONFIGURACIÓN. Deteniendo el Hunter."
    log "Revisa los parámetros del comando de creación."
    exit 1
  fi

  log ""
  log "Error distinto. Reintentando en ${INTERVAL_SECONDS}s..."
  sleep "$INTERVAL_SECONDS"
done
