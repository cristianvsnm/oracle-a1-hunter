#!/usr/bin/env bash

# ============================================================
# Oracle Cloud A1 Flex Hunter
# Minecraft Server
#
# Flujo:
#   1. Buscar Minecraft-Server
#   2. Si existe -> terminar
#   3. Si no existe -> intentar crear
#   4. Out of host capacity -> esperar y repetir
#   5. Si se crea -> terminar correctamente
# ============================================================

set -u

TENANCY_ID="${OCI_TENANCY_OCID:-}"
REGION="${OCI_REGION:-}"
DISPLAY_NAME="${OCI_DISPLAY_NAME:-Minecraft-Server}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-120}"

LOG_FILE="./hunter.log"
LAUNCH_FILE="./launch-request.json"

# ============================================================
# LOG
# ============================================================

log() {
    echo "$@" | tee -a "$LOG_FILE"
}

# ============================================================
# CABECERA
# ============================================================

log ""
log "============================================"
log " Oracle Cloud A1 Flex Hunter"
log " Minecraft Server"
log "============================================"
log ""
log "Region:       ${REGION:-desconocida}"
log "Display name: ${DISPLAY_NAME}"
log "Reintento:    cada ${INTERVAL_SECONDS}s"
log "Launch JSON:  ${LAUNCH_FILE}"
log ""

# ============================================================
# COMPROBACIONES
# ============================================================

if ! command -v oci >/dev/null 2>&1; then
    log "ERROR: OCI CLI no esta disponible."
    exit 1
fi

if [ -z "$TENANCY_ID" ]; then
    log "ERROR: OCI_TENANCY_OCID no esta definido."
    exit 1
fi

if [ -z "$REGION" ]; then
    log "ERROR: OCI_REGION no esta definido."
    exit 1
fi

if [ ! -f "$LAUNCH_FILE" ]; then
    log "ERROR: falta $LAUNCH_FILE"
    exit 1
fi

# ============================================================
# BUCLE PRINCIPAL
# ============================================================

ATTEMPT=0

while true; do

    ATTEMPT=$((ATTEMPT + 1))

    log ""
    log "--------------------------------------------"
    log "Intento #$ATTEMPT - $(date '+%Y-%m-%d %H:%M:%S')"
    log "--------------------------------------------"

    # ========================================================
    # BUSCAR SOLO Minecraft-Server
    # ========================================================

    log "Comprobando si ya existe ${DISPLAY_NAME}..."

    EXISTING_FILE="$(mktemp)"

    if ! oci compute instance list \
        --compartment-id "$TENANCY_ID" \
        --display-name "$DISPLAY_NAME" \
        --all \
        --output json > "$EXISTING_FILE" 2>instance-list-error.txt
    then

        RC=$?

        log ""
        log "ERROR consultando instancias."
        log ""

        if [ -f instance-list-error.txt ]; then
            cat instance-list-error.txt | tee -a "$LOG_FILE"
        fi

        rm -f "$EXISTING_FILE"

        log ""
        log "Esperando ${INTERVAL_SECONDS}s antes de volver a consultar..."
        sleep "$INTERVAL_SECONDS"

        continue
    fi

    # ========================================================
    # CONTAR INSTANCIAS
    # ========================================================

    COUNT="$(
        python - "$EXISTING_FILE" <<'PY'
import json
import sys

filename = sys.argv[1]

try:
    with open(filename, "r", encoding="utf-8") as f:
        data = json.load(f)

    instances = data.get("data", [])

    print(len(instances))

except Exception:
    print("-1")
PY
    )"

    # ========================================================
    # JSON INVALIDO
    # ========================================================

    if [ "$COUNT" = "-1" ]; then
        log ""
        log "ERROR: OCI devolvio una respuesta que no es JSON valido."
        log "Respuesta:"
        cat "$EXISTING_FILE" | tee -a "$LOG_FILE"

        rm -f "$EXISTING_FILE"

        log ""
        log "Esperando ${INTERVAL_SECONDS}s..."
        sleep "$INTERVAL_SECONDS"

        continue
    fi

    # ========================================================
    # YA EXISTE
    # ========================================================

    if [ "$COUNT" -gt 0 ]; then

        log ""
        log "============================================"
        log " Minecraft-Server YA EXISTE"
        log "============================================"
        log ""

        python - "$EXISTING_FILE" <<'PY' | tee -a "$LOG_FILE"
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)

for instance in data.get("data", []):
    print("Nombre :", instance.get("display-name"))
    print("OCID   :", instance.get("id"))
    print("Estado :", instance.get("lifecycle-state"))
    print("Shape  :", instance.get("shape"))
    print()
PY

        rm -f "$EXISTING_FILE"

        log "La instancia ya existe."
        log "El Hunter no creara otra."
        log ""

        exit 0
    fi

    # ========================================================
    # NO EXISTE
    # ========================================================

    rm -f "$EXISTING_FILE"

    log "No existe ${DISPLAY_NAME}."
    log "Esto es correcto."
    log ""

    # ========================================================
    # INTENTAR CREAR
    # ========================================================

    log "Intentando crear VM.Standard.A1.Flex..."

    OUTPUT_FILE="$(mktemp)"

    if oci compute instance launch \
        --from-json "file://$(pwd)/${LAUNCH_FILE}" \
        --output json > "$OUTPUT_FILE" 2>&1
    then

        # ====================================================
        # CREACION CORRECTA
        # ====================================================

        log ""
        log "============================================"
        log " INSTANCIA CREADA CORRECTAMENTE"
        log "============================================"
        log ""

        cat "$OUTPUT_FILE" | tee -a "$LOG_FILE"

        cp "$OUTPUT_FILE" resultado.json

        log ""
        log "Respuesta guardada en resultado.json"
        log ""

        rm -f "$OUTPUT_FILE"

        exit 0
    fi

    RC=$?

    # ========================================================
    # ERROR
    # ========================================================

    log ""
    log "Oracle devolvio un error:"
    log ""

    cat "$OUTPUT_FILE" | tee -a "$LOG_FILE"

    log ""

    # ========================================================
    # OUT OF HOST CAPACITY
    # ========================================================

    if grep -qiE \
        "Out of host capacity|Out of capacity|OutOfHostCapacity|HostCapacity" \
        "$OUTPUT_FILE"
    then

        log "SIN CAPACIDAD PARA A1 FLEX."
        log "Esperando ${INTERVAL_SECONDS}s..."
        log ""

        rm -f "$OUTPUT_FILE"

        sleep "$INTERVAL_SECONDS"

        continue
    fi

    # ========================================================
    # RATE LIMIT
    # ========================================================

    if grep -qiE \
        "TooManyRequests|429|Too Many Requests" \
        "$OUTPUT_FILE"
    then

        log "RATE LIMIT (429)."
        log "Esperando 5 minutos..."
        log ""

        rm -f "$OUTPUT_FILE"

        sleep 300

        continue
    fi

    # ========================================================
    # AUTENTICACION / AUTORIZACION
    # ========================================================

    if grep -qiE \
        "NotAuthenticated|NotAuthorized|401|403|NotAuthorizedOrNotFound" \
        "$OUTPUT_FILE"
    then

        log "ERROR DE AUTENTICACION/AUTORIZACION."
        log "El Hunter se detendra."
        log ""

        rm -f "$OUTPUT_FILE"

        exit 1
    fi

    # ========================================================
    # ERROR DE CONFIGURACION / REQUEST
    # ========================================================

    if grep -qiE \
        "CannotParseRequest|Incorrectly formatted request|Missing option|Unknown option|Invalid value for|Usage: oci|Invalid parameter|InvalidParameter" \
        "$OUTPUT_FILE"
    then

        log "============================================"
        log " ERROR DE CONFIGURACION"
        log "============================================"
        log ""
        log "Oracle rechazo el request."
        log "No tiene sentido seguir intentando el mismo request."
        log ""

        rm -f "$OUTPUT_FILE"

        exit 1
    fi

    # ========================================================
    # ERROR DESCONOCIDO
    # ========================================================

    log "Error no reconocido."
    log "Se volvera a intentar en ${INTERVAL_SECONDS}s."
    log ""

    rm -f "$OUTPUT_FILE"

    sleep "$INTERVAL_SECONDS"

done
