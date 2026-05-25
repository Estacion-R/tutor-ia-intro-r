# metricas.R · lectura del tutor.log y cálculo de métricas (issue #2 analytics)
#
# Lógica PURA (sin Shiny) → smoke-testeable con Rscript sin levantar la app
# (mismo patrón que las funciones de filtrado de shiny_eph_panel).
# El dashboard (app.R) solo orquesta UI + estos cálculos.

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(jsonlite)
})

`%||%` <- function(a, b) {
  if (is.null(a) || length(a) == 0 || (length(a) == 1 && is.na(a))) b else a
}

# Esquema vacío: se devuelve cuando no hay log o está vacío, para que el
# dashboard nunca rompa por columnas faltantes.
.LOG_VACIO <- function() {
  tibble::tibble(
    ts             = as.POSIXct(character(), tz = "UTC"),
    type           = character(),
    email          = character(),
    session_id     = character(),
    provider       = character(),
    categoria      = character(),
    pide_respuesta = logical(),
    input_chars    = integer(),
    response_chars = integer()
  )
}

# Lee el JSONL del tutor → tibble una-fila-por-evento. Tolera líneas viejas
# sin session_id/categoria (quedan NA) y líneas corruptas (se descartan).
cargar_log <- function(path) {
  if (!file.exists(path)) return(.LOG_VACIO())
  lineas <- readLines(path, warn = FALSE)
  lineas <- lineas[nzchar(trimws(lineas))]
  if (length(lineas) == 0) return(.LOG_VACIO())

  filas <- lapply(lineas, function(l) {
    e <- tryCatch(jsonlite::fromJSON(l, simplifyVector = FALSE),
                  error = function(err) NULL)
    if (is.null(e)) return(NULL)
    d <- if (is.list(e$details)) e$details else list()
    tibble::tibble(
      ts             = e$ts %||% NA_character_,
      type           = e$type %||% NA_character_,
      email          = e$email %||% NA_character_,
      session_id     = e$session_id %||% NA_character_,
      provider       = d$provider %||% NA_character_,
      categoria      = d$categoria %||% NA_character_,
      pide_respuesta = as.logical(d$pide_respuesta %||% NA),
      input_chars    = as.integer(d$input_chars %||% NA_integer_),
      response_chars = as.integer(d$response_chars %||% NA_integer_)
    )
  })
  filas <- Filter(Negate(is.null), filas)
  if (length(filas) == 0) return(.LOG_VACIO())

  out <- dplyr::bind_rows(filas)
  out$ts <- as.POSIXct(out$ts, format = "%Y-%m-%dT%H:%M:%OS", tz = "UTC")
  out
}

# Lee el log desde la Google Sheet persistente (hosting Connect Cloud/shinyapps).
# Mismo esquema que cargar_log(). Requiere auth gs4 previa (SA o interactiva,
# la resuelve app.R). Falla blando → tibble vacío si la planilla no se puede leer.
cargar_log_sheet <- function(sheet_id, hoja = 1) {
  raw <- tryCatch(
    googlesheets4::read_sheet(sheet_id, sheet = hoja, col_types = "c"),
    error = function(e) NULL
  )
  if (is.null(raw) || nrow(raw) == 0) return(.LOG_VACIO())
  # Tolera planillas parciales: asegura todas las columnas del esquema.
  for (col in SHEET_LOG_COLS_DASH) {
    if (is.null(raw[[col]])) raw[[col]] <- NA_character_
  }
  tibble::tibble(
    ts             = as.POSIXct(raw$ts, format = "%Y-%m-%dT%H:%M:%OS", tz = "UTC"),
    type           = as.character(raw$type),
    email          = as.character(raw$email),
    session_id     = as.character(raw$session_id),
    provider       = as.character(raw$provider),
    categoria      = as.character(raw$categoria),
    pide_respuesta = as.logical(raw$pide_respuesta),
    input_chars    = suppressWarnings(as.integer(raw$input_chars)),
    response_chars = suppressWarnings(as.integer(raw$response_chars))
  )
}

# Columnas esperadas en la planilla (debe coincidir con SHEET_LOG_COLS de
# app/registrar.R, sin la columna `details` que el dashboard no usa).
SHEET_LOG_COLS_DASH <- c("ts", "type", "email", "session_id", "provider",
                         "categoria", "pide_respuesta", "input_chars",
                         "response_chars")

# Latencia por turno: empareja cada chat_response con el chat_message previo
# de la misma sesión (los logs alternan message→response). Devuelve segundos.
.latencias <- function(df) {
  lat <- df |>
    filter(type %in% c("chat_message", "chat_response"),
           !is.na(session_id), !is.na(ts)) |>
    arrange(session_id, ts) |>
    group_by(session_id) |>
    mutate(ts_msg = if_else(type == "chat_message", ts,
                            as.POSIXct(NA, tz = "UTC"))) |>
    fill(ts_msg, .direction = "down") |>
    filter(type == "chat_response", !is.na(ts_msg)) |>
    mutate(lat_s = as.numeric(difftime(ts, ts_msg, units = "secs"))) |>
    ungroup() |>
    filter(is.finite(lat_s), lat_s >= 0)
  lat$lat_s
}

# Calcula todas las métricas sobre la ventana [desde, hasta] (fechas Date o
# coercibles). Devuelve una lista con escalares + data frames para graficar.
calcular_metricas <- function(df, desde = NULL, hasta = NULL) {
  if (!is.null(desde)) df <- df |> filter(!is.na(ts), as.Date(ts) >= as.Date(desde))
  if (!is.null(hasta)) df <- df |> filter(!is.na(ts), as.Date(ts) <= as.Date(hasta))

  msgs <- df |> filter(type == "chat_message")

  email_valido <- function(x) !is.na(x) & nzchar(x)
  alumnos <- unique(msgs$email[email_valido(msgs$email)])
  sesiones <- unique(msgs$session_id[!is.na(msgs$session_id)])

  # Distribución por tipo de consulta (NA → "sin clasificar")
  df_categoria <- msgs |>
    mutate(categoria = ifelse(is.na(categoria), "sin clasificar", categoria)) |>
    count(categoria, name = "n") |>
    arrange(desc(n))

  # Mensajes por día (serie temporal)
  df_por_dia <- msgs |>
    filter(!is.na(ts)) |>
    mutate(dia = as.Date(ts)) |>
    count(dia, name = "n") |>
    arrange(dia)

  # Tabla por alumno
  df_por_alumno <- msgs |>
    filter(email_valido(email)) |>
    group_by(email) |>
    summarise(
      sesiones      = n_distinct(session_id[!is.na(session_id)]),
      mensajes      = n(),
      pide_respuesta = sum(pide_respuesta %in% TRUE),
      ult_actividad = suppressWarnings(max(ts, na.rm = TRUE)),
      .groups = "drop"
    ) |>
    arrange(desc(mensajes))

  # Mensajes por sesión (para promedio)
  msgs_por_sesion <- msgs |>
    filter(!is.na(session_id)) |>
    count(session_id, name = "n")

  lat <- .latencias(df)

  n_fallback_msgs  <- sum(msgs$provider %in% "groq")
  n_fallback_event <- sum(df$type %in% "stream_fallback_to_groq")
  n_pide <- sum(msgs$pide_respuesta %in% TRUE)

  list(
    n_alumnos        = length(alumnos),
    n_sesiones       = length(sesiones),
    n_mensajes       = nrow(msgs),
    msgs_por_sesion  = if (nrow(msgs_por_sesion)) mean(msgs_por_sesion$n) else NA_real_,
    long_prom_input  = if (nrow(msgs)) mean(msgs$input_chars, na.rm = TRUE) else NA_real_,
    n_fallback_msgs  = n_fallback_msgs,
    n_fallback_event = n_fallback_event,
    lat_p50          = if (length(lat)) stats::median(lat) else NA_real_,
    lat_p95          = if (length(lat)) as.numeric(stats::quantile(lat, 0.95)) else NA_real_,
    n_pide           = n_pide,
    pct_pide         = if (nrow(msgs)) 100 * n_pide / nrow(msgs) else NA_real_,
    df_categoria     = df_categoria,
    df_por_dia       = df_por_dia,
    df_por_alumno    = df_por_alumno
  )
}
