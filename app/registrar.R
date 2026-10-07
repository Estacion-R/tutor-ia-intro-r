# registrar.R · sink OPCIONAL de logging a Google Sheet vía Apps Script web app
#
# En hosting con filesystem efímero (Posit Connect Cloud / shinyapps.io),
# `tutor.log` se borra al reiniciar/redeploy. Este módulo espeja cada evento a
# una Google Sheet para que la analytics (#2) y el auditor sobrevivan.
#
# SIN service account: la org bloquea la descarga de claves de SA
# (iam.disableServiceAccountKeyCreation). En su lugar, un Google Apps Script
# "web app" pegado a la Sheet recibe los eventos por POST y los appendea. Así no
# hay credencial de larga duración (respeta la política de seguridad).
#
# Se activa SOLO si están estas env vars (en local no se setean → la app loguea
# únicamente al archivo y el comportamiento de desarrollo queda intacto):
#   TUTOR_LOG_WEBHOOK_URL · URL del Apps Script web app (deploy del script de la Sheet)
#   TUTOR_LOG_TOKEN       · secreto compartido que el script valida (anti-abuso)
#
# El dashboard (app_admin/) lee la Sheet por separado con el login de Google del
# staff (googlesheets4 interactivo), no necesita esto.

suppressPackageStartupMessages({
  library(httr2)
  library(jsonlite)
})

if (!exists("%||%")) {
  `%||%` <- function(a, b) {
    if (is.null(a) || length(a) == 0 || (length(a) == 1 && is.na(a))) b else a
  }
}

# Estado del módulo: URL+token si está activo, NULL si no.
.tutor_log_url   <- NULL
.tutor_log_token <- NULL

# Inicializa el sink. Llamar una vez al arrancar la app. Devuelve TRUE si quedó
# activo. Falla blando si faltan env vars: nunca debe impedir que la app arranque.
init_sheets_logging <- function() {
  url   <- Sys.getenv("TUTOR_LOG_WEBHOOK_URL", "")
  token <- Sys.getenv("TUTOR_LOG_TOKEN", "")
  if (!nzchar(url) || !nzchar(token)) {
    message("Logging persistente inactivo (sin TUTOR_LOG_WEBHOOK_URL / TUTOR_LOG_TOKEN).")
    return(FALSE)
  }
  .tutor_log_url   <<- url
  .tutor_log_token <<- token
  message("Logging persistente ACTIVO (Apps Script webhook).")
  TRUE
}

# ¿Está activo el sink?
sheets_logging_activo <- function() !is.null(.tutor_log_url)

# Arma el payload del evento con el esquema fijo. Las primeras 10 columnas
# (hasta `details`) mantienen su orden histórico: el Apps Script viejo, que
# escribe por posición, sigue funcionando. Las columnas nuevas (model en
# adelante) van al final y las escribe el Apps Script nuevo, que mapea por el
# encabezado de la fila 1. `details` conserva el JSON completo (incluye los
# textos) para compatibilidad; `pregunta`/`respuesta` son las mismas strings en
# columna propia para leer la Sheet sin parsear JSON.
.evento_payload <- function(evt) {
  d <- if (is.list(evt$details)) {
    evt$details
  } else if (is.character(evt$details) && length(evt$details) == 1) {
    list(mensaje = evt$details)   # ej. error de ollama_init_failed
  } else list()
  ev <- list(
      ts             = evt$ts %||% NA_character_,
      type           = evt$type %||% NA_character_,
      email          = evt$email %||% NA_character_,
      session_id     = evt$session_id %||% NA_character_,
      provider       = d$provider %||% NA_character_,
      categoria      = d$categoria %||% NA_character_,
      pide_respuesta = if (is.null(d$pide_respuesta)) NA else isTRUE(d$pide_respuesta),
      input_chars    = d$input_chars %||% NA_integer_,
      response_chars = d$response_chars %||% NA_integer_,
      details        = if (length(d)) {
        as.character(jsonlite::toJSON(d, auto_unbox = TRUE, null = "null"))
      } else NA_character_,
      # --- columnas nuevas (2026-10-06) ---
      model          = d$model %||% NA_character_,
      prompt_version = evt$prompt_version %||% NA_character_,
      cohorte        = evt$cohorte %||% NA_character_,
      turno          = d$turno %||% NA_integer_,
      pregunta       = d$input_text %||% NA_character_,
      respuesta      = d$response_text %||% NA_character_,
      feedback       = d$feedback %||% NA_character_
  )
  # jsonlite serializa NA numérico como el string "NA". Se omiten los campos
  # vacíos: el Apps Script deja en blanco el encabezado sin campo.
  ev <- Filter(function(x) !(length(x) == 1 && is.na(x)), ev)
  list(token = .tutor_log_token, event = ev)
}

# Espeja un evento al Apps Script FUERA del critical path (later::later, delay 0
# → corre tras el flush reactivo, no bloquea la respuesta al alumno) y a prueba
# de fallos: si el POST falla, el evento queda igual en el log local.
append_evento_sheet <- function(evt) {
  if (!sheets_logging_activo()) return(invisible(NULL))
  payload <- .evento_payload(evt)
  later::later(function() {
    tryCatch(
      httr2::request(.tutor_log_url) |>
        httr2::req_body_json(payload) |>
        httr2::req_timeout(10) |>
        httr2::req_perform(),
      error = function(e) message("append webhook falló: ", conditionMessage(e))
    )
  }, delay = 0)
  invisible(NULL)
}
