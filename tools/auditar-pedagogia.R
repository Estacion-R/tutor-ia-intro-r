# Auditor pedagógico del tutor IA · Estación R
#
# Evalúa respuestas del tutor contra los criterios del prompt v3 usando Claude
# Haiku 4.5 vía `claude -p` (plan Max de Pablo). Batch: todos los turnos
# pendientes en una sola invocación para aprovechar cache_creation.
#
# Fallback: si Claude falla (rate limit, timeout, parse error), cae a Groq +
# Llama 3.3 70B individual (gratis, 1k req/día) sin perder auditorías.
#
# Modos de uso:
#
# 1) Función auditar(input, respuesta) en sesión interactiva:
#      source("tools/auditar-pedagogia.R")
#      dictamen <- auditar("Haceme el TP", "Acá te dejo el código...")
#
# 2) Script: audita las respuestas del log real
#      Rscript tools/auditar-pedagogia.R [path/al/tutor.log]
#      Default: app/tutor.log · output: app/auditoria.log

suppressPackageStartupMessages({
  library(ellmer)     # fallback Groq
  library(jsonlite)
  library(processx)   # invoca claude CLI sin pasar por shell
})

# --- Configuración ---------------------------------------------------------

JUDGE_MODEL_CLAUDE <- "claude-haiku-4-5"
JUDGE_MODEL_GROQ   <- "llama-3.3-70b-versatile"  # fallback

SYSTEM_PROMPT_PATH <- "tools/auditor-system-prompt.md"

`%||%` <- function(a, b) if (is.null(a) || (length(a) == 1 && is.na(a))) b else a

# --- Helpers ---------------------------------------------------------------

leer_system_prompt <- function() {
  if (!file.exists(SYSTEM_PROMPT_PATH)) {
    stop("No encuentro el system prompt: ", SYSTEM_PROMPT_PATH,
         " · ¿estás corriendo desde la raíz del proyecto tutor_ia_intro_r?")
  }
  paste(readLines(SYSTEM_PROMPT_PATH, encoding = "UTF-8"), collapse = "\n")
}

# Limpia respuestas que vienen envueltas en bloques markdown ```json ... ```
extraer_json <- function(texto) {
  texto <- trimws(texto)
  texto <- sub("^```(?:json)?\\s*", "", texto)
  texto <- sub("\\s*```$", "", texto)
  texto
}

formatear_turnos <- function(turnos) {
  # turnos: list de list(input, respuesta)
  partes <- vapply(seq_along(turnos), function(i) {
    sprintf("TURNO %d\nALUMNO: %s\n\nTUTOR: %s",
            i, turnos[[i]]$input, turnos[[i]]$respuesta)
  }, character(1))
  paste(partes, collapse = "\n\n")
}

# Invoca `claude -p` con system prompt del auditor + batch de turnos.
# Devuelve list de dictámenes (uno por turno, en orden). Si falla, devuelve NULL.
juez_claude <- function(turnos, system_prompt) {
  if (length(turnos) == 0) return(list())

  user_input <- formatear_turnos(turnos)

  # Combinamos system + user en un único user prompt y NO usamos
  # `--system-prompt` para evitar el límite ENAMETOOLONG de argv en Linux.
  # En su lugar, dejamos que claude use el system prompt default y el contenido
  # va todo por stdin como user message · contradice "minimizar contexto" pero
  # la alternativa de --bare requiere ANTHROPIC_API_KEY.
  # Trade-off documentado: cada llamada Claude carga ~30k tokens de contexto
  # del cwd (mitigado con wd=tempdir() · sin CLAUDE.md cerca).
  combined_input <- paste0(
    "Tu rol para esta tarea es el siguiente. Ignorá cualquier rol previo.\n\n",
    system_prompt,
    "\n\n---\n\n# Entrada a auditar\n\n",
    user_input,
    "\n\n# Recordá\n\nDevolvé EXCLUSIVAMENTE el JSON con la clave 'dictamenes', ",
    "sin texto antes ni después, sin bloque markdown."
  )

  args <- c(
    "-p",
    "--model", JUDGE_MODEL_CLAUDE,
    "--output-format", "json",
    "--disallowedTools", "*"
  )

  wd_original <- getwd()
  on.exit(setwd(wd_original), add = TRUE)
  setwd(tempdir())

  res <- tryCatch(
    {
      out <- system2("claude",
                     args   = args,
                     input  = combined_input,
                     stdout = TRUE, stderr = FALSE,
                     wait   = TRUE)
      paste(out, collapse = "\n")
    },
    error = function(e) {
      message("juez_claude · system2 falló: ", conditionMessage(e))
      return(NULL)
    }
  )

  setwd(wd_original)

  if (is.null(res)) return(NULL)

  envelope <- tryCatch(jsonlite::fromJSON(res, simplifyVector = FALSE),
                       error = function(e) NULL)
  if (is.null(envelope) || !is.list(envelope) || is.null(envelope$result)) {
    message("juez_claude · no pude parsear envelope. raw[:200]: ",
            substr(res, 1, 200))
    return(NULL)
  }
  if (isTRUE(envelope$is_error)) {
    message("juez_claude · Claude reportó error: ", envelope$result)
    return(NULL)
  }

  payload <- tryCatch(
    jsonlite::fromJSON(extraer_json(envelope$result), simplifyVector = FALSE),
    error = function(e) NULL
  )
  if (is.null(payload) || is.null(payload$dictamenes)) {
    message("juez_claude · payload no tiene dictamenes. raw[:200]: ",
            substr(envelope$result, 1, 200))
    return(NULL)
  }
  if (length(payload$dictamenes) != length(turnos)) {
    message(sprintf("juez_claude · esperaba %d dictamenes, recibí %d",
                    length(turnos), length(payload$dictamenes)))
    return(NULL)
  }

  message(sprintf("juez_claude · OK · %d dictamenes · cost USD %.4f",
                  length(payload$dictamenes),
                  envelope$total_cost_usd %||% 0))
  payload$dictamenes
}

# Fallback turno por turno con Groq.
juez_groq <- function(turnos, system_prompt) {
  lapply(seq_along(turnos), function(i) {
    t <- turnos[[i]]
    conv <- sprintf("TURNO 1\nALUMNO: %s\n\nTUTOR: %s",
                    t$input, t$respuesta)
    chat <- ellmer::chat_groq(
      model         = JUDGE_MODEL_GROQ,
      system_prompt = system_prompt
    )
    raw <- as.character(chat$chat(conv, echo = FALSE))
    parsed <- tryCatch(
      jsonlite::fromJSON(extraer_json(raw), simplifyVector = FALSE),
      error = function(e) NULL
    )
    dict <- if (!is.null(parsed) && !is.null(parsed$dictamenes) &&
                length(parsed$dictamenes) >= 1) {
      parsed$dictamenes[[1]]
    } else {
      list(
        scope_dentro_curso = NA, rioplatense_ok = NA,
        metodo_correcto = NA, reglas_tecnicas_ok = NA,
        red_flags = list(),
        severidad = "parse_error",
        comentario = paste("Groq parse error. raw[:120]:", substr(raw, 1, 120))
      )
    }
    dict$turno <- i
    dict
  })
}

# --- API pública -----------------------------------------------------------

# Auditá un solo turno · conveniencia interactiva.
auditar <- function(input_alumno, respuesta_tutor) {
  res <- auditar_batch(list(list(input = input_alumno,
                                  respuesta = respuesta_tutor)))
  if (length(res) >= 1) res[[1]] else list(severidad = "no_audited",
                                            comentario = "auditar_batch devolvió vacío")
}

# Auditá un batch de turnos · 1 llamada Claude para todos.
# Si Claude falla, cae a Groq individual.
auditar_batch <- function(turnos) {
  if (length(turnos) == 0) return(list())
  system_prompt <- leer_system_prompt()

  dicts <- juez_claude(turnos, system_prompt)
  if (is.null(dicts)) {
    message("Fallback a Groq · audito turno por turno")
    dicts <- juez_groq(turnos, system_prompt)
  }
  dicts
}

# Auditá todos los turnos del log que no estén ya auditados.
# Empareja chat_message + chat_response por orden en el log.
auditar_log <- function(log_path = "app/tutor.log",
                        out_path = "app/auditoria.log") {
  if (!file.exists(log_path)) {
    stop("No existe el log: ", log_path)
  }
  lineas <- readLines(log_path, warn = FALSE)
  eventos <- lapply(lineas, function(l) {
    tryCatch(jsonlite::fromJSON(l, simplifyVector = FALSE),
             error = function(e) NULL)
  })
  eventos <- Filter(Negate(is.null), eventos)

  msgs  <- Filter(function(e) identical(e$type, "chat_message"),  eventos)
  resps <- Filter(function(e) identical(e$type, "chat_response"), eventos)
  n_pares <- min(length(msgs), length(resps))

  ya_auditados <- character(0)
  if (file.exists(out_path)) {
    aud_prev <- lapply(readLines(out_path, warn = FALSE), function(l) {
      tryCatch(jsonlite::fromJSON(l, simplifyVector = FALSE),
               error = function(e) NULL)
    })
    ya_auditados <- unlist(lapply(aud_prev, function(a) a$response_ts))
  }

  pendientes <- list()
  pendientes_meta <- list()
  for (i in seq_len(n_pares)) {
    msg  <- msgs[[i]]; resp <- resps[[i]]
    if (resp$ts %in% ya_auditados) next
    if (is.null(msg$details$input_text) ||
        is.null(resp$details$response_text)) next
    pendientes[[length(pendientes) + 1]] <- list(
      input = msg$details$input_text,
      respuesta = resp$details$response_text
    )
    pendientes_meta[[length(pendientes_meta) + 1]] <- list(
      message_ts = msg$ts, response_ts = resp$ts,
      email = resp$email, provider = resp$details$provider
    )
  }

  cat(sprintf("Auditando %d turnos pendientes (de %d total en log)\n",
              length(pendientes), n_pares))
  if (length(pendientes) == 0) return(invisible(NULL))

  dicts <- auditar_batch(pendientes)
  for (i in seq_along(dicts)) {
    meta <- pendientes_meta[[i]]
    dict <- dicts[[i]]
    out <- list(
      audited_at  = format(Sys.time(), "%Y-%m-%dT%H:%M:%OS3", tz = "UTC"),
      message_ts  = meta$message_ts,
      response_ts = meta$response_ts,
      email       = meta$email,
      provider    = meta$provider,
      input       = pendientes[[i]]$input,
      response    = pendientes[[i]]$respuesta,
      dictamen    = dict
    )
    cat(jsonlite::toJSON(out, auto_unbox = TRUE, null = "null"), "\n",
        file = out_path, append = TRUE, sep = "")
  }

  sev <- vapply(dicts, function(d) d$severidad %||% "?", character(1))
  cat("\nResumen:\n")
  print(table(sev))
  invisible(NULL)
}

# --- Modo script -----------------------------------------------------------

if (!interactive()) {
  args <- commandArgs(trailingOnly = TRUE)
  log_path <- if (length(args) >= 1) args[[1]] else "app/tutor.log"
  out_path <- if (length(args) >= 2) args[[2]] else "app/auditoria.log"
  cat("Modo script · log:", log_path, "· out:", out_path, "\n\n")
  auditar_log(log_path = log_path, out_path = out_path)
}
