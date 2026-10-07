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

cat("latencia, fallback y error\n")
ev5 <- .evento_payload(list(
  ts = "t", type = "chat_response", email = "a@b.com", session_id = "s",
  details = list(provider = "gemini", model = "gemini-2.5-flash", turno = 2L,
                 fallback = TRUE, latencia_primer_token_ms = 1234L,
                 latencia_total_ms = 5678L, response_text = "x")
))$event
chequear("latencia al primer token", identical(ev5$latencia_primer_token_ms, 1234L))
chequear("latencia total", identical(ev5$latencia_total_ms, 5678L))
chequear("fallback TRUE", identical(ev5$fallback, TRUE))
chequear("error ausente → campo omitido", is.null(ev5$error))
ev6 <- .evento_payload(list(
  ts = "t", type = "chat_response", email = "a@b.com", session_id = "s",
  details = list(provider = "ollama", turno = 1L, fallback = FALSE)
))$event
chequear("fallback FALSE se conserva (no se omite)", identical(ev6$fallback, FALSE))
ev7 <- .evento_payload(list(
  ts = "t", type = "stream_failed", email = "a@b.com", session_id = "s",
  details = list(turno = 3L, error = TRUE, mensaje = "HTTP 401")
))$event
chequear("error TRUE", identical(ev7$error, TRUE))

cat("alumna_id\n")
Sys.setenv(TUTOR_ID_SALT = "")
chequear("sin sal → NA (no se emite hash sin sal)", is.na(alumna_id_de("a@b.com")))
Sys.setenv(TUTOR_ID_SALT = "sal-de-prueba")
id1 <- alumna_id_de("a@b.com")
chequear("con sal: formato a + 12 hex", grepl("^a[0-9a-f]{12}$", id1))
chequear("estable", identical(id1, alumna_id_de("a@b.com")))
chequear("normaliza mayúsculas y espacios", identical(id1, alumna_id_de("  A@B.com ")))
chequear("emails distintos → ids distintos", !identical(id1, alumna_id_de("c@d.com")))
Sys.setenv(TUTOR_ID_SALT = "otra-sal")
chequear("otra sal → otro id", !identical(id1, alumna_id_de("a@b.com")))
chequear("email vacío/NA → NA", is.na(alumna_id_de("")) && is.na(alumna_id_de(NA_character_)))
chequear("el id no contiene el email", !grepl("a@b", id1, fixed = TRUE))
ev8 <- .evento_payload(list(ts = "t", type = "login_ok", email = "a@b.com",
                            session_id = "s", alumna_id = id1))$event
chequear("alumna_id viaja en el payload", identical(ev8$alumna_id, id1))
Sys.setenv(TUTOR_ID_SALT = "")

cat(sprintf("\n%d ok, %d fallas\n", ok, fallos))
if (fallos > 0) quit(status = 1)
