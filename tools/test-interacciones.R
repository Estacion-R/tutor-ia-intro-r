# Test de app_admin/interacciones.R: la tabla de interacciones (una fila por turno)
# derivada del log crudo. Escenarios con log sintético en formato JSONL.
# Uso: Rscript tools/test-interacciones.R   (desde la raíz del repo)
suppressPackageStartupMessages({
  library(shiny)
  source("app_admin/metricas.R")
})

ok <- 0L; fallos <- 0L
chequear <- function(desc, cond) {
  if (isTRUE(cond)) { ok <<- ok + 1L; cat("  ok  ", desc, "\n") }
  else { fallos <<- fallos + 1L; cat("  FALLA", desc, "\n") }
}

ev <- function(ts, type, sid, d = NULL, email = "a@x.com", id = "a111111111aa")
  jsonlite::toJSON(list(ts = ts, type = type, email = email, session_id = sid,
                        alumna_id = id, cohorte = "c1", prompt_version = "v3.1-x",
                        details = d), auto_unbox = TRUE, null = "null")
G <- "glm-5.2"; F <- "gemini-2.5-flash"

lineas <- c(
  # S1 turno 1: normal, latencia explícita, feedback up luego down (gana el último)
  ev("2026-10-08T10:00:00.000", "chat_message", "S1", list(provider = "ollama", model = G, turno = 1, fallback = FALSE, categoria = "concepto", pide_respuesta = FALSE, input_chars = 4, input_text = "hola")),
  ev("2026-10-08T10:00:20.000", "chat_response", "S1", list(provider = "ollama", model = G, turno = 1, fallback = FALSE, latencia_primer_token_ms = 12000, latencia_total_ms = 20000, response_chars = 10, response_text = "respuesta1")),
  ev("2026-10-08T10:00:25.000", "feedback", "S1", list(model = G, turno = 1, feedback = "up")),
  ev("2026-10-08T10:00:30.000", "feedback", "S1", list(model = G, turno = 1, feedback = "down")),
  # S1 turno 2: Ollama falla, reintento con Gemini (mismo turno, 2 chat_message)
  ev("2026-10-08T10:01:00.000", "chat_message", "S1", list(provider = "ollama", model = G, turno = 2, fallback = FALSE, categoria = "error", input_chars = 5, input_text = "falla")),
  ev("2026-10-08T10:01:01.000", "stream_failed", "S1", list(provider = "ollama", model = G, turno = 2, error = TRUE, mensaje = "HTTP 401")),
  ev("2026-10-08T10:01:01.500", "stream_fallback_to_gemini", "S1"),
  ev("2026-10-08T10:01:02.000", "chat_message", "S1", list(provider = "gemini", model = F, turno = 2, reintento = TRUE, fallback = TRUE, categoria = "error", input_chars = 5, input_text = "falla")),
  ev("2026-10-08T10:01:06.000", "chat_response", "S1", list(provider = "gemini", model = F, turno = 2, fallback = TRUE, latencia_primer_token_ms = 1500, latencia_total_ms = 4000, response_chars = 9, response_text = "respuesta2")),
  # S1 turno 3: ni Ollama ni Gemini responden (sin chat_response)
  ev("2026-10-08T10:02:00.000", "chat_message", "S1", list(provider = "ollama", model = G, turno = 3, fallback = FALSE, input_text = "nada")),
  ev("2026-10-08T10:02:01.000", "stream_failed", "S1", list(provider = "ollama", model = G, turno = 3, error = TRUE, mensaje = "x")),
  ev("2026-10-08T10:02:02.000", "fallback_failed", "S1", list(turno = 3, error = TRUE, mensaje = "y")),
  # S2: formato VIEJO (sin turno, model, latencias): 2 consultas con sus respuestas
  ev("2026-10-01T09:00:00.000", "chat_message", "S2", list(provider = "ollama", categoria = "otro", pide_respuesta = TRUE, input_chars = 3, input_text = "uno"), email = "b@x.com", id = NULL),
  ev("2026-10-01T09:00:10.000", "chat_response", "S2", list(provider = "ollama", response_chars = 7, response_text = "r-uno"), email = "b@x.com", id = NULL),
  ev("2026-10-01T09:05:00.000", "chat_message", "S2", list(provider = "ollama", categoria = "otro", input_chars = 3, input_text = "dos"), email = "b@x.com", id = NULL),
  ev("2026-10-01T09:05:30.000", "chat_response", "S2", list(provider = "ollama", response_chars = 7, response_text = "r-dos"), email = "b@x.com", id = NULL)
)
tmp <- tempfile(fileext = ".log"); writeLines(lineas, tmp)
df <- cargar_log(tmp)
it <- armar_interacciones(df, incluir_email = TRUE)
fila <- function(s, t) it[it$session_id == s & it$turno == t, ]

cat("estructura\n")
chequear("una fila por turno (3 de S1 + 2 de S2)", nrow(it) == 5)
chequear("sin duplicar el turno reintentado", nrow(fila("S1", 2)) == 1)

cat("turno normal\n")
a <- fila("S1", 1)
chequear("pregunta y respuesta", a$pregunta == "hola" && a$respuesta == "respuesta1")
chequear("modelo glm-5.2", a$modelo == G)
chequear("latencias explícitas", a$latencia_primer_token_ms == 12000L && a$latencia_total_ms == 20000L)
chequear("feedback: gana el último (down)", a$feedback == "down")
chequear("sin fallback ni error", !a$fallback && !a$error && a$respondido && !a$reintento)
chequear("alumna_id y cohorte", a$alumna_id == "a111111111aa" && a$cohorte == "c1")

cat("turno con fallback tras error\n")
b <- fila("S1", 2)
chequear("respuesta de Gemini", b$modelo == F && b$respuesta == "respuesta2")
chequear("fallback + error + reintento", b$fallback && b$error && b$reintento)
chequear("latencia del chat_response final", b$latencia_total_ms == 4000L)

cat("turno sin respuesta\n")
c3 <- fila("S1", 3)
chequear("error y sin respuesta", c3$error && !c3$respondido && is.na(c3$respuesta))
chequear("conserva la pregunta", c3$pregunta == "nada")

cat("formato viejo\n")
v1 <- fila("S2", 1); v2 <- fila("S2", 2)
chequear("turnos asignados por orden (1 y 2)", nrow(v1) == 1 && nrow(v2) == 1)
chequear("cada respuesta en su turno", v1$respuesta == "r-uno" && v2$respuesta == "r-dos")
chequear("latencia total estimada por timestamps", v1$latencia_total_ms == 10000L && v2$latencia_total_ms == 30000L)
chequear("primer token NA (no se midió)", is.na(v1$latencia_primer_token_ms))
chequear("modelo NA, alumna_id NA", is.na(v1$modelo) && is.na(v1$alumna_id))

cat("tabla apta para compartir\n")
pub <- armar_interacciones(df)
chequear("sin columna email", !"email" %in% names(pub))
chequear("sí trae alumna_id", "alumna_id" %in% names(pub))
chequear("no aparece ningún email en ninguna celda",
         !any(grepl("@", unlist(lapply(pub, as.character)), fixed = TRUE)))

cat("reetiquetado de cohorte por mapeo email → cohorte\n")
mapa <- tibble::tibble(email = c(" B@X.com ", "otro@x.com", "vacio@x.com"),
                       cohorte = c("exalumno", "c9", "  "))
it2 <- armar_interacciones(df, incluir_email = TRUE, cohortes = mapa)
chequear("email del mapeo (sin importar mayúsculas/espacios) → exalumno",
         all(it2$cohorte[it2$email == "b@x.com"] == "exalumno"))
chequear("conserva la cohorte original en cohorte_registrada",
         all(it2$cohorte_registrada == it$cohorte))
chequear("email fuera del mapeo → queda la cohorte registrada",
         all(it2$cohorte[it2$email == "a@x.com"] == "c1"))
chequear("etiqueta vacía en el mapeo se ignora",
         identical(.aplicar_cohortes("vacio@x.com", "c1", mapa), "c1"))
chequear("sin mapeo, cohorte = cohorte_registrada",
         all(it$cohorte == it$cohorte_registrada, na.rm = TRUE))
chequear("tabla para compartir trae ambas columnas y sin email",
         all(c("cohorte", "cohorte_registrada") %in% names(armar_interacciones(df, cohortes = mapa))) &&
         !"email" %in% names(armar_interacciones(df, cohortes = mapa)))

cat("vacío\n")
chequear("df vacío → tabla vacía con columnas", nrow(armar_interacciones(.LOG_VACIO())) == 0 &&
         "alumna_id" %in% names(armar_interacciones(.LOG_VACIO())))

cat(sprintf("\n%d ok, %d fallas\n", ok, fallos))
if (fallos > 0) quit(status = 1)
