# metricas.R · lectura del tutor.log y cálculo de métricas (issue #2 analytics)
#
# Lógica PURA (sin Shiny) → smoke-testeable con Rscript sin levantar la app
# (mismo patrón que las funciones de filtrado de shiny_eph_panel).
# El dashboard (app.R) solo orquesta UI + estos cálculos.

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  # jsonlite NO se adjunta (se usa jsonlite::fromJSON): adjuntarlo después de
  # shiny hace que jsonlite::validate() tape a shiny::validate() y todos los
  # gráficos del dashboard fallen con "is.character(txt) is not TRUE".
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
    response_chars = integer(),
    model          = character(),
    turno          = integer(),
    feedback       = character(),
    pregunta       = character()
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
      response_chars = as.integer(d$response_chars %||% NA_integer_),
      model          = as.character(d$model %||% NA_character_),
      turno          = as.integer(d$turno %||% NA_integer_),
      feedback       = as.character(d$feedback %||% NA_character_),
      pregunta       = as.character(d$input_text %||% NA_character_)
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
    response_chars = suppressWarnings(as.integer(raw$response_chars)),
    # Columnas agregadas el 2026-10-06 (NA en filas previas).
    model          = as.character(raw$model),
    turno          = suppressWarnings(as.integer(raw$turno)),
    feedback       = as.character(raw$feedback),
    pregunta       = as.character(raw$pregunta)
  )
}

# Columnas esperadas en la planilla (nombres de columna de la Sheet = campos de
# .evento_payload en app/registrar.R; el dashboard no usa `details`).
SHEET_LOG_COLS_DASH <- c("ts", "type", "email", "session_id", "provider",
                         "categoria", "pide_respuesta", "input_chars",
                         "response_chars", "model", "turno", "feedback",
                         "pregunta")

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

# Quita del log las sesiones de prueba del staff: toda sesión con alguna pregunta
# que empiece con "[TEST" (convención de las pruebas) se descarta entera, así no
# se cuelan sus login/chat_init/feedback.
excluir_pruebas <- function(df) {
  if (!nrow(df)) return(df)
  sid_test <- unique(df$session_id[
    df$type %in% "chat_message" & !is.na(df$pregunta) &
      startsWith(df$pregunta, "[TEST") & !is.na(df$session_id)])
  if (!length(sid_test)) return(df)
  df[is.na(df$session_id) | !(df$session_id %in% sid_test), ]
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
    left_join(
      df |>
        filter(type == "feedback", feedback %in% c("up", "down"),
               email_valido(email)) |>
        group_by(email) |>
        summarise(up = sum(feedback == "up"), down = sum(feedback == "down"),
                  .groups = "drop"),
      by = "email") |>
    mutate(up = coalesce(up, 0L), down = coalesce(down, 0L)) |>
    arrange(desc(mensajes))

  # Mensajes por sesión (para promedio)
  msgs_por_sesion <- msgs |>
    filter(!is.na(session_id)) |>
    count(session_id, name = "n")

  lat <- .latencias(df)

  # Fallback = consultas atendidas por Gemini (el primario es Ollama/glm-5.2).
  n_fallback_msgs  <- sum(msgs$provider %in% "gemini")
  n_fallback_event <- sum(df$type %in% "stream_fallback_to_gemini")
  n_pide <- sum(msgs$pide_respuesta %in% TRUE)

  # --- Modelo que respondió + feedback 👍/👎 (columnas desde 2026-10-06) ---
  resp <- df |> filter(type == "chat_response")
  fb   <- df |> filter(type == "feedback", feedback %in% c("up", "down"))
  n_up   <- sum(fb$feedback == "up")
  n_down <- sum(fb$feedback == "down")

  df_modelo <- resp |>
    mutate(modelo = ifelse(is.na(model), "sin dato (previo al 06/10)", model)) |>
    group_by(modelo) |>
    summarise(respuestas = n(), .groups = "drop") |>
    left_join(
      fb |>
        mutate(modelo = ifelse(is.na(model), "sin dato (previo al 06/10)", model)) |>
        group_by(modelo) |>
        summarise(up = sum(feedback == "up"), down = sum(feedback == "down"),
                  .groups = "drop"),
      by = "modelo") |>
    mutate(up = coalesce(up, 0L), down = coalesce(down, 0L),
           pct_up = ifelse(up + down > 0, 100 * up / (up + down), NA_real_)) |>
    arrange(desc(respuestas))

  # Largo de las sesiones: turno máximo por sesión (1 = una sola consulta).
  turno_max <- msgs |>
    filter(!is.na(session_id), !is.na(turno)) |>
    group_by(session_id) |>
    summarise(turnos = suppressWarnings(max(turno)), .groups = "drop")
  df_turnos <- turno_max |>
    mutate(tramo = factor(ifelse(turnos >= 5, "5 o más", as.character(turnos)),
                          levels = c("1", "2", "3", "4", "5 o más"))) |>
    count(tramo, name = "sesiones", .drop = FALSE)

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
    n_resp           = nrow(resp),
    n_fb_up          = n_up,
    n_fb_down        = n_down,
    pct_calificadas  = if (nrow(resp)) 100 * (n_up + n_down) / nrow(resp) else NA_real_,
    pct_up           = if (n_up + n_down > 0) 100 * n_up / (n_up + n_down) else NA_real_,
    turnos_prom      = if (nrow(turno_max)) mean(turno_max$turnos) else NA_real_,
    df_modelo        = df_modelo,
    df_turnos        = df_turnos,
    df_categoria     = df_categoria,
    df_por_dia       = df_por_dia,
    df_por_alumno    = df_por_alumno
  )
}
