# registrar.R · sink OPCIONAL de logging a Google Sheet (persistencia en la nube)
#
# En hosting con filesystem efímero (Posit Connect Cloud / shinyapps.io),
# `tutor.log` se borra al reiniciar/redeploy. Este módulo espeja cada evento a
# una Google Sheet para que la analytics (#2) y el auditor sobrevivan.
#
# Se activa SOLO si están estas env vars (en local no se setean → la app loguea
# únicamente al archivo y el comportamiento de desarrollo queda intacto):
#   TUTOR_LOG_SHEET_ID · id de la planilla destino (de la URL de la Sheet)
#   GOOGLE_SA_JSON     · CONTENIDO del JSON de la service account (no un path:
#                        así la key va como secreto de entorno y NUNCA se
#                        commitea al repo de Connect Cloud)
#
# La service account necesita la Google Sheets API habilitada en su proyecto y
# la planilla compartida con su email (rol Editor).

suppressPackageStartupMessages({
  library(googlesheets4)
  library(jsonlite)
})

if (!exists("%||%")) {
  `%||%` <- function(a, b) {
    if (is.null(a) || length(a) == 0 || (length(a) == 1 && is.na(a))) b else a
  }
}

# Estado del módulo: id de la planilla si está activo, NULL si no.
.tutor_sheet_id <- NULL

# Esquema fijo de columnas (orden estable: sheet_append alinea por posición y el
# dashboard lee por estos nombres). `details` lleva el resto serializado a JSON.
SHEET_LOG_COLS <- c("ts", "type", "email", "session_id", "provider",
                    "categoria", "pide_respuesta", "input_chars",
                    "response_chars", "details")

# Inicializa el sink. Llamar una vez al arrancar la app. Devuelve TRUE si quedó
# activo. Falla blando (FALSE + message) si faltan env vars o la auth falla:
# nunca debe impedir que la app arranque.
init_sheets_logging <- function() {
  sheet_id <- Sys.getenv("TUTOR_LOG_SHEET_ID", "")
  sa_json  <- Sys.getenv("GOOGLE_SA_JSON", "")
  if (!nzchar(sheet_id) || !nzchar(sa_json)) {
    message("Sheets logging inactivo (sin TUTOR_LOG_SHEET_ID / GOOGLE_SA_JSON).")
    return(FALSE)
  }
  tryCatch({
    tmp <- tempfile(fileext = ".json")
    writeLines(sa_json, tmp)
    googlesheets4::gs4_auth(
      path   = tmp,
      scopes = "https://www.googleapis.com/auth/spreadsheets"
    )
    .tutor_sheet_id <<- sheet_id
    message("Sheets logging ACTIVO sobre planilla ", substr(sheet_id, 1, 8), "…")
    TRUE
  }, error = function(e) {
    message("init_sheets_logging falló: ", conditionMessage(e))
    FALSE
  })
}

# ¿Está activo el sink?
sheets_logging_activo <- function() !is.null(.tutor_sheet_id)

# Convierte un evento (lista con ts/type/email/session_id/details) a una fila
# del esquema fijo. El details completo (incluye input_text/response_text) va
# serializado en la columna `details`.
.evento_a_fila_sheet <- function(evt) {
  d <- if (is.list(evt$details)) evt$details else list()
  data.frame(
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
    stringsAsFactors = FALSE
  )
}

# Espeja un evento a la planilla FUERA del critical path (later::later, delay 0
# → corre tras el flush reactivo, no bloquea la respuesta al alumno) y a prueba
# de fallos: si la API de Sheets falla, el evento queda igual en el log local.
append_evento_sheet <- function(evt) {
  if (!sheets_logging_activo()) return(invisible(NULL))
  fila <- .evento_a_fila_sheet(evt)
  later::later(function() {
    tryCatch(
      googlesheets4::sheet_append(.tutor_sheet_id, fila),
      error = function(e) message("sheet_append falló: ", conditionMessage(e))
    )
  }, delay = 0)
  invisible(NULL)
}
