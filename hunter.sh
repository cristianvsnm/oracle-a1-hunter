#!/usr/bin/env bash

# ============================================================
# Oracle Cloud A1 Flex Hunter
# Minecraft Server
#
# LISTADO:
#   Usa OCI Python SDK para comprobar si existe Minecraft-Server.
#
# CREACION:
#   Usa OCI CLI + --from-json para lanzar la instancia.
#
# FLUJO:
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

if ! python -c "import oci" >/dev/null 2>&1; then
    log "ERROR: Python OCI SDK no esta disponible."
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
# FUNCION: BUSCAR Minecraft-Server
#
# Usa OCI Python SDK.
# No depende del stdout de "oci compute instance list".
#
# Salida:
#   0 -> no existe
#   1 -> existe
#   2 -> error
# ============================================================

check_existing_instance() {

    python - "$DISPLAY_NAME" <<'PY'
import os
import sys
import oci

display_name = sys.argv[1]

try:
    config = oci.config.from_file(
        os.path.expanduser("~/.oci/config"),
        "DEFAULT"
    )

    compute = oci.core.ComputeClient(config)

    response = compute.list_instances(
        compartment_id=config["tenancy"],
        display_name=display_name
    )

    instances = response.data

    print("INSTANCES_COUNT=" + str(len(instances)))

    if not instances:
        sys.exit(0)

    for instance in instances:
        print("INSTANCE_NAME=" + str(instance.display_name))
        print("INSTANCE_ID=" + str(instance.id))
        print("INSTANCE_STATE=" + str(instance.lifecycle_state))
        print("INSTANCE_SHAPE=" + str(instance.shape))

    sys.exit(1)

except Exception as e:
    print("SDK_ERROR=" + repr(e))
    sys.exit(2)
PY

}

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
    # BUSCAR INSTANCIA EXISTENTE
    # ========================================================

    log "Comprobando si ya existe ${DISPLAY_NAME}..."
    log ""

    CHECK_OUTPUT="$(check_existing_instance 2>&1)"
    CHECK_RC=$?

    log "$CHECK_OUTPUT"

    # ========================================================
    # ERROR CONSULTANDO OCI
    # ========================================================

    if [ "$CHECK_RC" -eq 2 ]; then

        log ""
        log "ERROR consultando instancias mediante OCI SDK."
        log "Esperando ${INTERVAL_SECONDS}s antes de volver a intentar."
        log ""

        sleep "$INTERVAL_SECONDS"
        continue
    fi

    # ========================================================
    # YA EXISTE
    # ========================================================

    if [ "$CHECK_RC" -eq 1 ]; then

        log ""
        log "============================================"
        log " Minecraft-Server YA EXISTE"
        log "============================================"
        log ""
        log "El Hunter no creara otra instancia."
        log ""

        exit 0
    fi

    # ========================================================
    # NO EXISTE
    # ========================================================

    log ""
    log "No existe ${DISPLAY_NAME}."
    log "Esto es correcto."
    log ""

    # ========================================================
    # INTENTAR CREAR
    # ========================================================

    log "Intentando crear VM.Standard.A1.Flex..."
    log ""

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

    # ========================================================
    # ERROR DE CREACION
    # ========================================================

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
    # ERROR DE CONFIGURACION
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
        log "No se seguira intentando el mismo request."
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
