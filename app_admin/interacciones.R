# interacciones.R · tabla de interacciones derivada del log crudo
#
# Una fila por TURNO (una consulta de una alumna y su respuesta), armada a partir
# del log crudo de eventos (tutor.log o la Sheet). El crudo es la fuente de verdad
# (append-only, no se edita); esta tabla se recalcula siempre desde él.
#
# Lógica PURA (sin Shiny, sin I/O): testeable con Rscript. La usan el panel
# (metricas.R) y tools/exportar-interacciones.R.

suppressPackageStartupMessages(library(dplyr))

# Eventos que cuentan como error de un turno.
.TIPOS_ERROR <- c("stream_failed", "chat_response_rejected", "fallback_failed")

.INTERACCIONES_VACIO <- function() {
  tibble::tibble(
    ts             = as.POSIXct(character(), tz = "UTC"),
    session_id     = character(),
    turno          = integer(),
    alumna_id      = character(),
    email          = character(),
    cohorte        = character(),
    cohorte_registrada = character(),
    prompt_version = character(),
    categoria      = character(),
    pide_respuesta = logical(),
    pregunta       = character(),
    respuesta      = character(),
    modelo         = character(),
    provider       = character(),
    latencia_primer_token_ms = integer(),
    latencia_total_ms        = integer(),
    feedback       = character(),
    fallback       = logical(),
    error          = logical(),
    reintento      = logical(),
    respondido     = logical(),
    input_chars    = integer(),
    response_chars = integer()
  )
}

# Primer / último valor no-NA (conserva el tipo; NA tipado si no hay ninguno).
.primero <- function(x) { x <- x[!is.na(x)]; if (length(x)) x[[1]] else x[NA_integer_][1] }
.ultimo  <- function(x) { x <- x[!is.na(x)]; if (length(x)) x[[length(x)]] else x[NA_integer_][1] }

# Reetiqueta la cohorte según el mapeo email → cohorte (comparación sin
# distinguir mayúsculas ni espacios). Sin mapeo o sin coincidencia: la original.
.aplicar_cohortes <- function(email, cohorte, cohortes) {
  if (is.null(cohortes) || !nrow(cohortes)) return(cohorte)
  k_map <- tolower(trimws(cohortes$email))
  nuevo <- cohortes$cohorte[match(tolower(trimws(email)), k_map)]
  nuevo <- ifelse(!is.na(nuevo) & nzchar(trimws(nuevo)), trimws(nuevo), NA_character_)
  dplyr::coalesce(nuevo, cohorte)
}

# df: log crudo (columnas de cargar_log()/cargar_log_sheet()).
# incluir_email = FALSE (default) → tabla apta para compartir: solo `alumna_id`.
# TRUE → agrega `email` (uso interno del panel de staff).
#
# cohortes: opcional, tibble(email, cohorte) con el mapeo email → cohorte/etiqueta
# (pestaña `cohortes` de la Sheet o CSV local). Si el email del turno está en el
# mapeo, `cohorte` toma ese valor; si no, queda la que registró la app. La que
# registró la app se conserva SIEMPRE en `cohorte_registrada` (auditoría).
#
# Reglas:
# - El turno sale de la columna `turno`; en filas viejas (previas al 06/10, sin
#   turno) se asigna por orden dentro de la sesión (n-ésimo chat_message).
# - Un turno reintentado tras fallback (varios chat_message con el mismo turno)
#   es UNA fila: `reintento = TRUE`, `error = TRUE`, `fallback = TRUE`.
# - Latencia: la medida explícita (ms) de chat_response; si falta (filas viejas),
#   se estima el total por diferencia de timestamps y el primer token queda NA.
# - `fallback`: la respuesta salió de Gemini (respaldo). `error`: hubo algún error
#   en el turno (stream falló, promesa rechazada, respaldo falló).
# - `respondido = FALSE`: hubo consulta pero ninguna respuesta registrada.
armar_interacciones <- function(df, incluir_email = FALSE, cohortes = NULL) {
  if (!nrow(df)) return(.INTERACCIONES_VACIO())

  ev <- df |>
    filter(!is.na(session_id), !is.na(ts),
           type %in% c("chat_message", "chat_response", "feedback", .TIPOS_ERROR)) |>
    arrange(session_id, ts) |>
    group_by(session_id) |>
    mutate(turno_ef = dplyr::coalesce(turno, as.integer(cumsum(type == "chat_message")))) |>
    ungroup() |>
    filter(turno_ef > 0L)
  if (!nrow(ev)) return(.INTERACCIONES_VACIO())

  inter <- ev |>
    group_by(session_id, turno = turno_ef) |>
    summarise(
      .ts_msg  = .primero(ts[type == "chat_message"]),
      .ts_resp = .ultimo(ts[type == "chat_response"]),
      .ts_any  = min(ts),
      alumna_id      = .primero(alumna_id),
      email          = .primero(email),
      cohorte        = .primero(cohorte),
      prompt_version = .primero(prompt_version),
      categoria      = .primero(categoria[type == "chat_message"]),
      pide_respuesta = any(pide_respuesta[type == "chat_message"] %in% TRUE),
      pregunta       = .primero(pregunta[type == "chat_message"]),
      respuesta      = .ultimo(respuesta[type == "chat_response"]),
      modelo         = dplyr::coalesce(.ultimo(model[type == "chat_response"]),
                                       .ultimo(model[type == "chat_message"])),
      provider       = dplyr::coalesce(.ultimo(provider[type == "chat_response"]),
                                       .ultimo(provider[type == "chat_message"])),
      .lat1          = .ultimo(latencia_primer_token_ms[type == "chat_response"]),
      .lat2          = .ultimo(latencia_total_ms[type == "chat_response"]),
      feedback       = .ultimo(feedback[type == "feedback" & feedback %in% c("up", "down")]),
      fallback       = any(fallback[type %in% c("chat_message", "chat_response")] %in% TRUE) |
                       any(provider[type %in% c("chat_message", "chat_response")] %in% "gemini"),
      error          = any(type %in% .TIPOS_ERROR) | any(error %in% TRUE),
      reintento      = sum(type == "chat_message") > 1,
      respondido     = any(type == "chat_response"),
      input_chars    = .primero(input_chars[type == "chat_message"]),
      response_chars = .ultimo(response_chars[type == "chat_response"]),
      .groups = "drop"
    ) |>
    mutate(
      ts = dplyr::coalesce(.ts_msg, .ts_any),
      latencia_primer_token_ms = as.integer(.lat1),
      latencia_total_ms = dplyr::coalesce(
        as.integer(.lat2),
        ifelse(!is.na(.ts_msg) & !is.na(.ts_resp) & .ts_resp >= .ts_msg,
               as.integer(round(as.numeric(difftime(.ts_resp, .ts_msg, units = "secs")) * 1000)),
               NA_integer_))
    ) |>
    arrange(ts, session_id, turno) |>
    mutate(cohorte_registrada = cohorte,
           cohorte = .aplicar_cohortes(email, cohorte, cohortes)) |>
    select(ts, session_id, turno, alumna_id, email, cohorte, cohorte_registrada, prompt_version,
           categoria, pide_respuesta, pregunta, respuesta, modelo, provider,
           latencia_primer_token_ms, latencia_total_ms, feedback, fallback,
           error, reintento, respondido, input_chars, response_chars)

  if (!incluir_email) inter$email <- NULL
  inter
}
