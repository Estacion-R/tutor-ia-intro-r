# Test offline del payload que app/registrar.R manda al Apps Script.
# Uso: Rscript tools/test-registrar.R   (desde la raíz del repo)
# Verifica el esquema: columnas históricas intactas + columnas nuevas, y que
# `details` siga trayendo todo (compatibilidad con el Apps Script viejo).
source("app/registrar.R")
.tutor_log_token <- "t"

ok <- 0L; fallos <- 0L
chequear <- function(desc, cond) {
  if (isTRUE(cond)) { ok <<- ok + 1L; cat("  ok  ", desc, "\n") }
  else { fallos <<- fallos + 1L; cat("  FALLA", desc, "\n") }
}

evt <- list(
  ts = "2026-10-06T20:00:00.000", type = "chat_response",
  email = "a@b.com", session_id = "sid1",
  prompt_version = "v3.1-abcd1234", cohorte = "intro-r-s2-2026",
  details = list(provider = "ollama", model = "glm-5.2", turno = 2L,
                 response_chars = 11L, response_text = "hola mundo")
)
ev <- .evento_payload(evt)$event
cat("chat_response\n")
chequear("model", identical(ev$model, "glm-5.2"))
chequear("prompt_version", identical(ev$prompt_version, "v3.1-abcd1234"))
chequear("cohorte", identical(ev$cohorte, "intro-r-s2-2026"))
chequear("turno", identical(ev$turno, 2L))
chequear("respuesta en columna propia", identical(ev$respuesta, "hola mundo"))
chequear("details sigue incluyendo el texto", grepl("hola mundo", ev$details))
chequear("provider (columna histórica)", identical(ev$provider, "ollama"))

ev2 <- .evento_payload(list(
  ts = "t", type = "chat_message", email = "a@b.com", session_id = "s",
  details = list(provider = "gemini", model = "gemini-2.5-flash", turno = 1L,
                 categoria = "error", pide_respuesta = FALSE,
                 input_chars = 5L, input_text = "¿qué?")
))$event
cat("chat_message\n")
chequear("pregunta en columna propia", identical(ev2$pregunta, "¿qué?"))
chequear("respuesta vacía (campo omitido)", is.null(ev2$respuesta))
chequear("prompt_version ausente (campo omitido)", is.null(ev2$prompt_version))
chequear("sin strings \"NA\" en el JSON", !grepl("\"NA\"", as.character(jsonlite::toJSON(ev2, auto_unbox = TRUE))))

ev3 <- .evento_payload(list(
  ts = "t", type = "feedback", email = "a@b.com", session_id = "s",
  details = list(provider = "ollama", model = "glm-5.2", turno = 3L,
                 feedback = "down")
))$event
cat("feedback\n")
chequear("feedback", identical(ev3$feedback, "down"))
chequear("turno del feedback", identical(ev3$turno, 3L))

ev4 <- .evento_payload(list(
  ts = "t", type = "ollama_init_failed", email = NA, session_id = "s",
  details = "HTTP 401 Unauthorized"
))$event
cat("details string (error)\n")
chequear("el mensaje de error no se pierde", grepl("401", ev4$details))

cat(sprintf("\n%d ok, %d fallas\n", ok, fallos))
if (fallos > 0) quit(status = 1)
