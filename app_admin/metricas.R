# metricas.R · lectura del tutor.log y cálculo de métricas (issue #2 analytics)
#
# Lógica PURA (sin Shiny) → smoke-testeable con Rscript sin levantar la app
# (mismo patrón que las funciones de filtrado de shiny_eph_panel).
# El dashboard (app.R) solo orquesta UI + estos cálculos.

suppressPackageStartupMessages({
  library(dplyr)
  # jsonlite NO se adjunta (se usa jsonlite::fromJSON): adjuntarlo después de
  # shiny hace que jsonlite::validate() tape a shiny::validate() y todos los
  # gráficos del dashboard fallen con "is.character(txt) is not TRUE".
})

`%||%` <- function(a, b) {
  if (is.null(a) || length(a) == 0 || (length(a) == 1 && is.na(a))) b else a
}

# Tabla derivada de interacciones (una fila por turno). Se sourcea desde el mismo
# directorio que metricas.R.
source(if (file.exists("interacciones.R")) "interacciones.R" else "app_admin/interacciones.R")

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
    pregunta       = character(),
    respuesta      = character(),
    alumna_id      = character(),
    cohorte        = character(),
    prompt_version = character(),
    latencia_primer_token_ms = integer(),
    latencia_total_ms        = integer(),
    fallback       = logical(),
    error          = logical()
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
      pregunta       = as.character(d$input_text %||% NA_character_),
      respuesta      = as.character(d$response_text %||% NA_character_),
      alumna_id      = as.character(e$alumna_id %||% NA_character_),
      cohorte        = as.character(e$cohorte %||% NA_character_),
      prompt_version = as.character(e$prompt_version %||% NA_character_),
      latencia_primer_token_ms = as.integer(d$latencia_primer_token_ms %||% NA_integer_),
      latencia_total_ms        = as.integer(d$latencia_total_ms %||% NA_integer_),
      fallback       = as.logical(d$fallback %||% NA),
      # en filas viejas `error` era el texto del error (string): cuenta como error
      error          = if (is.null(d$error)) NA else (isTRUE(d$error) || is.character(d$error))
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
    pregunta       = as.character(raw$pregunta),
    respuesta      = as.character(raw$respuesta),
    alumna_id      = as.character(raw$alumna_id),
    cohorte        = as.character(raw$cohorte),
    prompt_version = as.character(raw$prompt_version),
    latencia_primer_token_ms = suppressWarnings(as.integer(raw$latencia_primer_token_ms)),
    latencia_total_ms        = suppressWarnings(as.integer(raw$latencia_total_ms)),
    fallback       = as.logical(raw$fallback),
    error          = as.logical(raw$error)
  )
}

# Columnas esperadas en la planilla (nombres de columna de la Sheet = campos de
# .evento_payload en app/registrar.R; el dashboard no usa `details`).
SHEET_LOG_COLS_DASH <- c("ts", "type", "email", "session_id", "provider",
                         "categoria", "pide_respuesta", "input_chars",
                         "response_chars", "model", "turno", "feedback",
                         "pregunta", "respuesta", "alumna_id", "cohorte",
                         "prompt_version", "latencia_primer_token_ms",
                         "latencia_total_ms", "fallback", "error")

# Mapeo email → cohorte/etiqueta (ej. "exalumno"). Fuente única: la pestaña
# `cohortes` de la misma Sheet del log (columnas email, cohorte, nota). Fuera de la
# Sheet (log local): CSV con las mismas columnas. Falla blando → mapeo vacío
# (queda la cohorte que registró la app).
.COHORTES_VACIO <- function() tibble::tibble(email = character(), cohorte = character())
.normalizar_cohortes <- function(raw) {
  if (is.null(raw) || !nrow(raw) || !all(c("email", "cohorte") %in% names(raw))) {
    return(.COHORTES_VACIO())
  }
  out <- tibble::tibble(email = as.character(raw$email), cohorte = as.character(raw$cohorte))
  out[!is.na(out$email) & nzchar(trimws(out$email)) &
        !is.na(out$cohorte) & nzchar(trimws(out$cohorte)), ]
}
cargar_cohortes_sheet <- function(sheet_id, hoja = "cohortes") {
  raw <- tryCatch(googlesheets4::read_sheet(sheet_id, sheet = hoja, col_types = "c"),
                  error = function(e) NULL)
  .normalizar_cohortes(raw)
}
cargar_cohortes_csv <- function(path) {
  if (!file.exists(path)) return(.COHORTES_VACIO())
  raw <- tryCatch(utils::read.csv(path, stringsAsFactors = FALSE, encoding = "UTF-8"),
                  error = function(e) NULL)
  .normalizar_cohortes(raw)
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
# coercibles). Las métricas por turno salen de la tabla de interacciones
# (armar_interacciones), no de los eventos sueltos. Devuelve una lista con
# escalares + data frames para graficar.
calcular_metricas <- function(df, desde = NULL, hasta = NULL,
                              cohortes = NULL, cohorte = NULL) {
  inter <- armar_interacciones(df, incluir_email = TRUE, cohortes = cohortes)
  if (!is.null(cohorte) && nzchar(cohorte)) inter <- inter |> filter(cohorte %in% !!cohorte)
  if (!is.null(desde)) inter <- inter |> filter(!is.na(ts), as.Date(ts) >= as.Date(desde))
  if (!is.null(hasta)) inter <- inter |> filter(!is.na(ts), as.Date(ts) <= as.Date(hasta))

  valido <- function(x) !is.na(x) & nzchar(x)
  # Clave de alumna para el staff: el email (si está) y, si no, el id seudónimo.
  inter <- inter |> mutate(alumna = ifelse(valido(email), email, alumna_id))

  cuenta_na <- function(x) ifelse(is.na(x), "sin clasificar", x)
  lat_total_s <- inter$latencia_total_ms[inter$respondido] / 1000
  lat_1er_s   <- inter$latencia_primer_token_ms[inter$respondido] / 1000
  p <- function(x, q) if (sum(!is.na(x))) as.numeric(stats::quantile(x, q, na.rm = TRUE)) else NA_real_

  df_categoria <- inter |>
    mutate(categoria = cuenta_na(categoria)) |>
    count(categoria, name = "n") |>
    arrange(desc(n))

  df_por_dia <- inter |>
    filter(!is.na(ts)) |>
    mutate(dia = as.Date(ts)) |>
    count(dia, name = "n") |>
    arrange(dia)

  df_por_alumno <- inter |>
    filter(valido(alumna)) |>
    group_by(alumna) |>
    summarise(
      sesiones       = n_distinct(session_id),
      mensajes       = n(),
      pide_respuesta = sum(pide_respuesta %in% TRUE),
      up             = sum(feedback %in% "up"),
      down           = sum(feedback %in% "down"),
      fallbacks      = sum(fallback %in% TRUE),
      errores        = sum(error %in% TRUE),
      ult_actividad  = suppressWarnings(max(ts, na.rm = TRUE)),
      .groups = "drop"
    ) |>
    arrange(desc(mensajes))

  turno_max <- inter |>
    group_by(session_id) |>
    summarise(turnos = max(turno), .groups = "drop")
  df_turnos <- turno_max |>
    mutate(tramo = factor(ifelse(turnos >= 5, "5 o más", as.character(turnos)),
                          levels = c("1", "2", "3", "4", "5 o más"))) |>
    count(tramo, name = "sesiones", .drop = FALSE)

  # Respuestas por modelo (las previas al 06/10 no traen el modelo).
  df_modelo <- inter |>
    filter(respondido) |>
    mutate(modelo = ifelse(is.na(modelo), "sin dato (previo al 06/10)", modelo)) |>
    group_by(modelo) |>
    summarise(
      respuestas = n(),
      up         = sum(feedback %in% "up"),
      down       = sum(feedback %in% "down"),
      p50_s      = if (sum(!is.na(latencia_total_ms))) stats::median(latencia_total_ms, na.rm = TRUE) / 1000 else NA_real_,
      .groups = "drop"
    ) |>
    mutate(pct_up = ifelse(up + down > 0, 100 * up / (up + down), NA_real_)) |>
    arrange(desc(respuestas))

  n_resp <- sum(inter$respondido)
  n_up   <- sum(inter$feedback %in% "up")
  n_down <- sum(inter$feedback %in% "down")
  n_pide <- sum(inter$pide_respuesta %in% TRUE)
  n_msgs <- nrow(inter)
  msgs_por_sesion <- inter |> count(session_id, name = "n")

  list(
    n_alumnos        = n_distinct(inter$alumna[valido(inter$alumna)]),
    n_sesiones       = n_distinct(inter$session_id),
    n_mensajes       = n_msgs,
    msgs_por_sesion  = if (nrow(msgs_por_sesion)) mean(msgs_por_sesion$n) else NA_real_,
    long_prom_input  = if (n_msgs) mean(inter$input_chars, na.rm = TRUE) else NA_real_,
    n_fallback_msgs  = sum(inter$fallback %in% TRUE),
    n_errores        = sum(inter$error %in% TRUE),
    n_sin_respuesta  = sum(!inter$respondido),
    lat_p50          = p(lat_total_s, 0.5),
    lat_p95          = p(lat_total_s, 0.95),
    lat1_p50         = p(lat_1er_s, 0.5),
    lat1_p95         = p(lat_1er_s, 0.95),
    n_pide           = n_pide,
    pct_pide         = if (n_msgs) 100 * n_pide / n_msgs else NA_real_,
    n_resp           = n_resp,
    n_fb_up          = n_up,
    n_fb_down        = n_down,
    pct_calificadas  = if (n_resp) 100 * (n_up + n_down) / n_resp else NA_real_,
    pct_up           = if (n_up + n_down > 0) 100 * n_up / (n_up + n_down) else NA_real_,
    turnos_prom      = if (nrow(turno_max)) mean(turno_max$turnos) else NA_real_,
    df_modelo        = df_modelo,
    df_turnos        = df_turnos,
    df_categoria     = df_categoria,
    df_por_dia       = df_por_dia,
    df_por_alumno    = df_por_alumno
  )
}
