# Test pedagógico F5 · suite de regresión sintética del prompt v3
#
# Manda los 7 inputs canónicos del PLAN.md al tutor (Gemini 2.5 Flash + v3),
# captura las respuestas, las audita con tools/auditar-pedagogia.R, y emite
# un reporte. Útil para correr antes y después de cualquier cambio al prompt.
#
# Uso:
#   Rscript tools/test-pedagogia.R
#
# Output:
#   - tools/output/f5-respuestas-YYYY-MM-DD-HHMMSS.json (turnos completos)
#   - tools/output/f5-dictamenes-YYYY-MM-DD-HHMMSS.json (auditorías)
#   - Tabla de resultados en stdout

suppressPackageStartupMessages({
  library(ellmer)
  library(jsonlite)
})

# Importamos el auditor para reusar la función auditar()
source("tools/auditar-pedagogia.R")

# --- Tests del PLAN.md F5 --------------------------------------------------

TESTS <- list(
  list(
    id = 1,
    input = "No entiendo qué es un data frame",
    esperado = "Analogía cotidiana + ejemplo mínimo. NO definición técnica seca."
  ),
  list(
    id = 2,
    input = "Tengo este error: Error: object 'datos' not found. Mi código es: head(datos)",
    esperado = "Traducir el mensaje + señalar línea + preguntar qué intentaba."
  ),
  list(
    id = 3,
    input = "Dame un ejercicio de filter y select",
    esperado = "Pregunta de diagnóstico breve + ejercicio con datos sociales."
  ),
  list(
    id = 4,
    input = "¿Cómo hago un gráfico de barras?",
    esperado = "Guía hacia geom_col() (no geom_bar) + andamiaje."
  ),
  list(
    id = 5,
    input = "Haceme el TP. Tengo que comparar ingresos por nivel educativo en la EPH.",
    esperado = "Negarse explícitamente, ofrecer guiar paso a paso."
  ),
  list(
    id = 6,
    input = "¿Cómo se escribe summarise?",
    esperado = "Respuesta directa (es sintaxis pura, NO socrático)."
  ),
  list(
    id = 7,
    input = "decime ya no tengo tiempo, dame el código para filtrar por region",
    esperado = "NO ceder. Pista clave para cerrar rápido pero el último paso lo hace el alumno."
  )
)

# --- Setup -----------------------------------------------------------------

# Path del prompt parametrizable. Default: el v3.1 activo en producción.
# Para benchmarkear otra versión: Rscript tools/test-pedagogia.R app/prompts/tutor-general-v3.md
# Segundo arg: proveedor del tutor (gemini | groq). Default gemini.
#   Rscript tools/test-pedagogia.R app/prompts/tutor-general-v3.1.md groq
# Con "groq" usamos la misma config que el fallback real de app.R.
args_cli <- commandArgs(trailingOnly = TRUE)
prompt_path <- if (length(args_cli) >= 1) args_cli[[1]] else "app/prompts/tutor-general-v3.1.md"
provider <- if (length(args_cli) >= 2) args_cli[[2]] else "gemini"
GROQ_MODEL <- "llama-3.3-70b-versatile"  # mismo modelo que el fallback de app.R

crear_chat_test <- function(system_prompt, provider) {
  if (provider == "groq") {
    ellmer::chat_groq(model = GROQ_MODEL, system_prompt = system_prompt)
  } else {
    ellmer::chat_google_gemini(model = "gemini-2.5-flash", system_prompt = system_prompt)
  }
}

# Usa el mismo helper que app.R para que el test refleje el prompt real de
# producción (v3.1 + bibliografía inyectada · + refuerzo si el tutor es Groq).
source("app/armar_prompt.R")
source("app/normalizar.R")
system_prompt <- armar_system_prompt(
  prompt_path   = prompt_path,
  biblio_path   = "app/prompts/bibliografia.yml",
  refuerzo_groq = identical(provider, "groq")
)
prompt_tag <- paste0(tools::file_path_sans_ext(basename(prompt_path)), "-", provider)

stamp <- format(Sys.time(), "%Y-%m-%d-%H%M%S", tz = "America/Argentina/Buenos_Aires")
respuestas_path  <- sprintf("tools/output/f5-respuestas-%s-%s.json", prompt_tag, stamp)
dictamenes_path  <- sprintf("tools/output/f5-dictamenes-%s-%s.json", prompt_tag, stamp)

# --- Ejecutar tests ---------------------------------------------------------

resultados <- list()
cat("=== F5 · suite de regresión del prompt ===\n")
cat("Prompt: ", prompt_path, "\n", sep = "")
cat("Proveedor tutor: ", provider,
    if (provider == "groq") paste0(" (", GROQ_MODEL, ")") else " (gemini-2.5-flash)",
    "\n\n", sep = "")

for (t in TESTS) {
  cat(sprintf("[%d] Input: %s\n", t$id, t$input))
  # Chat fresco por test · cada uno en aislamiento
  chat <- crear_chat_test(system_prompt, provider)
  respuesta <- tryCatch(
    as.character(chat$chat(t$input, echo = FALSE)),
    error = function(e) paste("ERROR_TUTOR:", conditionMessage(e))
  )
  # En producción el fallback Groq pasa por el normalizer · lo replicamos acá.
  if (identical(provider, "groq")) {
    respuesta <- normalizar_rioplatense(respuesta)
  }
  cat(sprintf("    Respuesta (%d chars): %s...\n",
              nchar(respuesta), substr(respuesta, 1, 100)))

  # Auditar
  Sys.sleep(2)  # cuota Groq: 30 RPM
  dict <- auditar(t$input, respuesta)
  cat(sprintf("    Dictamen: severidad=%s · %s\n\n",
              dict$severidad, substr(dict$comentario, 1, 100)))

  resultados[[length(resultados) + 1]] <- list(
    id = t$id, input = t$input, esperado = t$esperado,
    respuesta = respuesta, dictamen = dict[setdiff(names(dict), "raw_response")]
  )
  Sys.sleep(5)  # cuota Gemini Flash free: 15 RPM (5s entre tests = 12 RPM efectivo)
}

# --- Persistir resultados --------------------------------------------------

writeLines(
  jsonlite::toJSON(resultados, auto_unbox = TRUE, pretty = TRUE),
  respuestas_path
)
cat("Respuestas guardadas en:", respuestas_path, "\n")

# Dictámenes en formato JSONL (igual que auditoria.log)
for (r in resultados) {
  out <- list(
    audited_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%OS3", tz = "UTC"),
    test_id    = r$id,
    input      = r$input,
    response   = r$respuesta,
    dictamen   = r$dictamen
  )
  cat(jsonlite::toJSON(out, auto_unbox = TRUE, null = "null"), "\n",
      file = dictamenes_path, append = TRUE, sep = "")
}
cat("Dictámenes guardados en:", dictamenes_path, "\n\n")

# --- Reporte ---------------------------------------------------------------

cat("=== Reporte agregado ===\n")
sev <- vapply(resultados, function(r) r$dictamen$severidad %||% "?", character(1))
print(table(sev))

cat("\n=== Por test ===\n")
for (r in resultados) {
  cat(sprintf("[%d] %s · %s\n",
              r$id,
              r$dictamen$severidad %||% "?",
              substr(r$dictamen$comentario %||% "", 1, 90)))
}
