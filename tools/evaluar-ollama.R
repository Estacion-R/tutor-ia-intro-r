# Evaluación de modelos Ollama Cloud como alternativa al stack actual.
#
# Por cada modelo cloud: corre los 7 inputs canónicos de F5 contra el prompt
# v3.1, mide latencia, audita con Claude (`auditar()`). Compara con baseline
# Gemini Flash (5 ok / 2 menor) y v3.1 (6 ok / 1 menor).
#
# Output:
# - tools/output/ollama-eval-YYYY-MM-DD-HHMMSS.json (raw)
# - tools/output/ollama-eval-YYYY-MM-DD-HHMMSS.md  (reporte legible)
#
# Uso:
#   Rscript tools/evaluar-ollama.R                # default: 3 modelos cloud
#   Rscript tools/evaluar-ollama.R "modelo1:cloud,modelo2:cloud"

suppressPackageStartupMessages({
  library(ellmer)
  library(jsonlite)
})

# Evita que el main de auditar-pedagogia.R (modo script) corra al source-earlo
# como librería desde este harness (ver sentinel en auditar-pedagogia.R).
Sys.setenv(AUDITAR_NO_MAIN = "1")
source("tools/auditar-pedagogia.R")

`%||%` <- function(a, b) if (is.null(a) || (length(a) == 1 && is.na(a))) b else a

# --- Config ----------------------------------------------------------------

# Base URL de Ollama Cloud. Si la API real es distinta, ajustar acá.
# Ollama por convención usa el host raíz para cloud + sufijo :cloud en model.
OLLAMA_BASE_URL <- Sys.getenv("OLLAMA_BASE_URL", "https://ollama.com")

# Modelos a evaluar. Verificado 2026-05-18 que están en Free tier:
# (deepseek-v4-flash, kimi-k2.6, gemini-3-flash-preview requieren Pro).
MODELOS_DEFAULT <- c(
  "qwen3-coder-next",    # ~80GB · familia Qwen · más rápido (0.93s en probe)
  "gpt-oss:20b",         # ~14GB · GPT-OSS de OpenAI · 1.45s
  "gemma4:31b"           # ~62GB · Gemma 4 último de Google · 5.02s
)

LATENCIA_WARMUP <- 1  # primer request descarta (warmup)

TESTS <- list(
  list(id = 1, input = "No entiendo qué es un data frame"),
  list(id = 2, input = "Tengo este error: Error: object 'datos' not found. Mi código es: head(datos)"),
  list(id = 3, input = "Dame un ejercicio de filter y select"),
  list(id = 4, input = "¿Cómo hago un gráfico de barras?"),
  list(id = 5, input = "Haceme el TP. Tengo que comparar ingresos por nivel educativo en la EPH."),
  list(id = 6, input = "¿Cómo se escribe summarise?"),
  list(id = 7, input = "decime ya no tengo tiempo, dame el código para filtrar por region")
)

# Baselines (corridas previas con Gemini Flash + v3.1) para comparación.
BASELINE <- list(
  modelo = "gemini-2.5-flash + v3.1",
  fecha = "2026-05-17",
  ok = 6, menor = 1, moderada = 0, grave = 0,
  notas = "Baseline activa en producción. Latencia P50 ~2-3s observada en logs."
)

# --- Helpers ---------------------------------------------------------------

cargar_prompt <- function(path = "app/prompts/tutor-general-v3.1.md") {
  paste(readLines(path, encoding = "UTF-8"), collapse = "\n")
}

evaluar_modelo <- function(modelo, system_prompt) {
  cat(sprintf("\n========== %s ==========\n", modelo))
  resultados <- list()

  for (t in TESTS) {
    cat(sprintf("[%d] %s...\n", t$id, substr(t$input, 1, 60)))

    chat <- tryCatch(
      ellmer::chat_ollama(
        base_url      = OLLAMA_BASE_URL,
        credentials   = function() list(
          Authorization = paste("Bearer", Sys.getenv("OLLAMA_API_KEY"))
        ),
        model         = modelo,
        system_prompt = system_prompt
      ),
      error = function(e) {
        cat(sprintf("  ERROR init: %s\n", conditionMessage(e)))
        NULL
      }
    )
    if (is.null(chat)) {
      resultados[[length(resultados) + 1]] <- list(
        test_id = t$id, input = t$input,
        respuesta = NA_character_, latencia_s = NA,
        dictamen = list(severidad = "init_error",
                        comentario = "No se pudo inicializar chat")
      )
      next
    }

    t0 <- Sys.time()
    respuesta <- tryCatch(
      as.character(chat$chat(t$input, echo = FALSE)),
      error = function(e) paste("ERROR:", conditionMessage(e))
    )
    latencia_s <- as.numeric(difftime(Sys.time(), t0, units = "secs"))

    cat(sprintf("  Respuesta (%d chars, %.2fs): %s...\n",
                nchar(respuesta), latencia_s,
                substr(respuesta, 1, 80)))

    # Auditar con Claude (reusa función de auditar-pedagogia.R)
    Sys.sleep(1)
    dict <- if (startsWith(respuesta, "ERROR")) {
      list(severidad = "request_error",
           comentario = respuesta)
    } else {
      auditar(t$input, respuesta)
    }
    cat(sprintf("  Dictamen: %s\n", dict$severidad %||% "?"))

    resultados[[length(resultados) + 1]] <- list(
      test_id    = t$id,
      input      = t$input,
      respuesta  = respuesta,
      latencia_s = latencia_s,
      dictamen   = dict[setdiff(names(dict), "raw_response")]
    )

    Sys.sleep(2)  # margen entre tests para no agotar cuota Ollama
  }

  resultados
}

resumir_modelo <- function(resultados) {
  if (length(resultados) == 0) {
    return(list(ok = 0, menor = 0, moderada = 0, grave = 0,
                otros = 0, lat_p50 = NA, lat_p95 = NA))
  }
  sev <- vapply(resultados,
                function(r) r$dictamen$severidad %||% "?", character(1))
  # Descartar primer turno como warmup para latencia
  lats <- vapply(resultados[-seq_len(min(LATENCIA_WARMUP, length(resultados)))],
                 function(r) r$latencia_s %||% NA_real_, numeric(1))
  lats <- lats[!is.na(lats)]
  list(
    ok       = sum(sev == "ok"),
    menor    = sum(sev == "menor"),
    moderada = sum(sev == "moderada"),
    grave    = sum(sev == "grave"),
    otros    = sum(!sev %in% c("ok", "menor", "moderada", "grave")),
    lat_p50  = if (length(lats) > 0) quantile(lats, 0.5) else NA,
    lat_p95  = if (length(lats) > 0) quantile(lats, 0.95) else NA
  )
}

generar_markdown <- function(all_results, baseline) {
  lineas <- c(
    "# Evaluación Ollama Cloud · benchmark contra Gemini Flash baseline",
    "",
    sprintf("**Generado:** %s",
            format(Sys.time(), "%Y-%m-%d %H:%M %Z")),
    sprintf("**Base URL:** `%s`", OLLAMA_BASE_URL),
    sprintf("**Modelos evaluados:** %d",
            length(all_results)),
    sprintf("**Tests por modelo:** %d (suite F5 canónica)", length(TESTS)),
    sprintf("**Prompt:** `tutor-general-v3.1.md`"),
    sprintf("**Judge:** Claude Haiku 4.5 (vía `auditar()`)"),
    "",
    "## Tabla comparativa",
    "",
    "| Modelo | ok | menor | moderada | grave | err | lat P50 (s) | lat P95 (s) |",
    "|---|---|---|---|---|---|---|---|"
  )

  # Baseline primero
  lineas <- c(lineas,
              sprintf("| **%s** (baseline) | %d | %d | %d | %d | - | - | - |",
                      baseline$modelo, baseline$ok, baseline$menor,
                      baseline$moderada, baseline$grave))

  for (mod in names(all_results)) {
    res <- all_results[[mod]]
    if (is.null(res)) {
      lineas <- c(lineas,
                  sprintf("| %s | ERROR · ver detalle abajo | | | | | | |", mod))
      next
    }
    r <- resumir_modelo(res)
    lineas <- c(lineas,
      sprintf("| %s | %d | %d | %d | %d | %d | %s | %s |",
              mod, r$ok, r$menor, r$moderada, r$grave, r$otros,
              if (is.na(r$lat_p50)) "-" else sprintf("%.2f", r$lat_p50),
              if (is.na(r$lat_p95)) "-" else sprintf("%.2f", r$lat_p95)))
  }

  lineas <- c(lineas, "",
              "## Recomendación",
              "",
              "_(completar manualmente tras revisar la tabla)_",
              "",
              "**Criterios:**",
              "- Si algún modelo cloud supera baseline en F5 (≥7 ok) y latencia P95 ≤5s → considerar como primario.",
              "- Si free tier alcanza para una cohorte de 30 alumnos × 10 sesiones × 8 turnos = 2.4k req/mes: NO necesario pagar Pro.",
              "- Si Pro USD 20/mes habilita modelos significativamente mejores que cumplen v3.1 y la cuota free se queda corta: justificar pago.",
              "- Si Free alcanza y ningún modelo supera a Gemini: cerrar issue #5 como 'evaluado, no conviene cambiar'.",
              "",
              "## Detalle por modelo")

  for (mod in names(all_results)) {
    res <- all_results[[mod]]
    if (is.null(res)) {
      lineas <- c(lineas, "",
                  sprintf("### %s", mod),
                  "",
                  "Error en evaluación · ver logs de la corrida.")
      next
    }
    lineas <- c(lineas, "",
                sprintf("### %s", mod),
                "")
    for (r in res) {
      lineas <- c(lineas,
                  sprintf("- **Test %d** · %s · %.2fs · `%s`",
                          r$test_id,
                          r$dictamen$severidad %||% "?",
                          r$latencia_s %||% NA,
                          substr(r$dictamen$comentario %||% "", 1, 200)))
    }
  }

  paste(lineas, collapse = "\n")
}

# --- Modo script -----------------------------------------------------------

if (!interactive()) {
  if (Sys.getenv("OLLAMA_API_KEY") == "") {
    stop("OLLAMA_API_KEY no está en ~/.Renviron · ",
         "hacer signin en https://ollama.com/ y configurar la key primero")
  }

  args_cli <- commandArgs(trailingOnly = TRUE)
  modelos <- if (length(args_cli) >= 1) strsplit(args_cli[[1]], ",")[[1]] else MODELOS_DEFAULT
  modelos <- trimws(modelos)

  cat(sprintf("Evaluando %d modelos: %s\n",
              length(modelos), paste(modelos, collapse = ", ")))

  system_prompt <- cargar_prompt()
  all_results <- list()
  for (m in modelos) {
    all_results[[m]] <- tryCatch(
      evaluar_modelo(m, system_prompt),
      error = function(e) {
        cat(sprintf("\nMODELO %s FALLÓ: %s\n", m, conditionMessage(e)))
        NULL
      }
    )
  }

  stamp <- format(Sys.time(), "%Y-%m-%d-%H%M%S",
                  tz = "America/Argentina/Buenos_Aires")
  json_path <- sprintf("tools/output/ollama-eval-%s.json", stamp)
  md_path   <- sprintf("tools/output/ollama-eval-%s.md", stamp)

  writeLines(jsonlite::toJSON(all_results, auto_unbox = TRUE, pretty = TRUE),
             json_path)
  writeLines(generar_markdown(all_results, BASELINE), md_path)

  cat(sprintf("\n=== Reporte ===\n"))
  cat(sprintf("JSON:     %s\n", json_path))
  cat(sprintf("Markdown: %s\n", md_path))

  cat("\n=== Resumen ejecutivo ===\n")
  cat(sprintf("Baseline %s: %d ok / %d menor\n",
              BASELINE$modelo, BASELINE$ok, BASELINE$menor))
  for (m in names(all_results)) {
    res <- all_results[[m]]
    if (is.null(res)) { cat(sprintf("%s: ERROR\n", m)); next }
    r <- resumir_modelo(res)
    cat(sprintf("%s: %d ok / %d menor / %d moderada / %d grave · P50 %s · P95 %s\n",
                m, r$ok, r$menor, r$moderada, r$grave,
                if (is.na(r$lat_p50)) "-" else sprintf("%.2fs", r$lat_p50),
                if (is.na(r$lat_p95)) "-" else sprintf("%.2fs", r$lat_p95)))
  }
}
