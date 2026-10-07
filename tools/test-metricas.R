# Smoke test de app_admin/metricas.R con un log sintético (formato JSONL local).
# Uso: Rscript tools/test-metricas.R   (desde la raíz del repo)
suppressPackageStartupMessages({
  library(shiny)                      # mismo orden que app_admin/app.R
  source("app_admin/metricas.R")
})

ok <- 0L; fallos <- 0L
chequear <- function(desc, cond) {
  if (isTRUE(cond)) { ok <<- ok + 1L; cat("  ok  ", desc, "\n") }
  else { fallos <<- fallos + 1L; cat("  FALLA", desc, "\n") }
}

ev <- function(ts, type, email, sid, d = NULL)
  jsonlite::toJSON(list(ts = ts, type = type, email = email, session_id = sid,
                        details = d), auto_unbox = TRUE, null = "null")
msg <- function(ts, e, s, t, m, txt)
  ev(ts, "chat_message", e, s, list(provider = if (grepl("gemini", m)) "gemini" else "ollama",
     model = m, turno = t, categoria = "concepto", pide_respuesta = FALSE,
     input_chars = nchar(txt), input_text = txt))
resp <- function(ts, e, s, t, m)
  ev(ts, "chat_response", e, s, list(model = m, turno = t, response_chars = 500L))
fb <- function(ts, e, s, t, m, v)
  ev(ts, "feedback", e, s, list(model = m, turno = t, feedback = v))

G <- "glm-5.2"; F <- "gemini-2.5-flash"
lineas <- c(
  # alumna A: 3 turnos con glm, 👍 y 👎
  msg("2026-10-08T10:00:00.000", "a@x.com", "sA", 1, G, "hola"),
  resp("2026-10-08T10:00:20.000", "a@x.com", "sA", 1, G),
  fb("2026-10-08T10:00:25.000", "a@x.com", "sA", 1, G, "up"),
  msg("2026-10-08T10:01:00.000", "a@x.com", "sA", 2, G, "otra"),
  resp("2026-10-08T10:01:30.000", "a@x.com", "sA", 2, G),
  fb("2026-10-08T10:01:35.000", "a@x.com", "sA", 2, G, "down"),
  msg("2026-10-08T10:02:00.000", "a@x.com", "sA", 3, G, "tercera"),
  resp("2026-10-08T10:02:10.000", "a@x.com", "sA", 3, G),
  # alumna B: 1 turno atendido por Gemini (fallback), sin feedback
  msg("2026-10-08T11:00:00.000", "b@x.com", "sB", 1, F, "ayuda"),
  resp("2026-10-08T11:00:08.000", "b@x.com", "sB", 1, F),
  # staff: sesión de prueba (debe excluirse)
  msg("2026-10-08T12:00:00.000", "s@x.com", "sT", 1, G, "[TEST staff] probando"),
  resp("2026-10-08T12:00:09.000", "s@x.com", "sT", 1, G),
  fb("2026-10-08T12:00:12.000", "s@x.com", "sT", 1, G, "up"),
  # fila vieja, sin model/turno (formato previo al 06/10)
  ev("2026-10-01T09:00:00.000", "chat_message", "v@x.com", "sV",
     list(provider = "ollama", categoria = "otro", pide_respuesta = TRUE, input_chars = 10L))
)
tmp <- tempfile(fileext = ".log"); writeLines(lineas, tmp)

df <- cargar_log(tmp)
cat("regresión: metricas.R no debe tapar shiny::validate\n")
chequear("validate() sigue siendo el de shiny", identical(validate, shiny::validate))

cat("carga\n")
chequear("columnas nuevas presentes", all(c("model", "turno", "feedback", "pregunta") %in% names(df)))
chequear("fila vieja carga con model NA", is.na(df$model[df$session_id == "sV"][1]))

cat("excluir_pruebas\n")
d2 <- excluir_pruebas(df)
chequear("saca toda la sesión de prueba", !any(d2$session_id %in% "sT"))
chequear("conserva las sesiones reales", all(c("sA", "sB", "sV") %in% d2$session_id))

cat("métricas (sin pruebas)\n")
m <- calcular_metricas(d2)
chequear("feedback: 1 up y 1 down", m$n_fb_up == 1 && m$n_fb_down == 1)
chequear("respuestas = 4", m$n_resp == 4)
chequear("% calificadas = 50", isTRUE(all.equal(m$pct_calificadas, 50)))
chequear("fallbacks a Gemini = 1", m$n_fallback_msgs == 1)
chequear("modelos: glm-5.2 (3), gemini (1)",
         identical(sort(m$df_modelo$respuestas), c(1L, 3L)) &&
         all(c("glm-5.2", "gemini-2.5-flash") %in% m$df_modelo$modelo))
chequear("turnos: sA=3, sB=1 → prom 2", isTRUE(all.equal(m$turnos_prom, 2)))
chequear("df_turnos suma 2 sesiones", sum(m$df_turnos$sesiones) == 2)
chequear("alumna A: 1 up 1 down", {
  a <- m$df_por_alumno[m$df_por_alumno$email == "a@x.com", ]
  a$up == 1 && a$down == 1 })

cat("métricas (con pruebas, para contraste)\n")
m_con <- calcular_metricas(df)
chequear("sin excluir, el up de la prueba cuenta (2)", m_con$n_fb_up == 2)

cat("carga desde Sheet (read_sheet simulado, todo texto como en producción)\n")
raw <- tibble::tibble(
  ts = "2026-10-08T10:00:00.000", type = "chat_message", email = "a@x.com",
  session_id = "sS", provider = "ollama", categoria = "concepto",
  pide_respuesta = "FALSE", input_chars = "12", response_chars = NA_character_,
  details = "{}", model = "glm-5.2", prompt_version = "v3.1-b794b0bc",
  cohorte = "intro-r-s2-2026", turno = "1", pregunta = "hola", respuesta = NA_character_,
  feedback = NA_character_)
utils::assignInNamespace("read_sheet", function(...) raw, "googlesheets4")
ds <- cargar_log_sheet("fake")
chequear("model y turno tipados", identical(ds$model, "glm-5.2") && identical(ds$turno, 1L))
chequear("pide_respuesta lógico", identical(ds$pide_respuesta, FALSE))
raw_viejo <- raw[, c("ts", "type", "email", "session_id", "provider")]
utils::assignInNamespace("read_sheet", function(...) raw_viejo, "googlesheets4")
chequear("Sheet con solo columnas viejas no rompe", is.na(cargar_log_sheet("fake")$model))

cat("log vacío no rompe\n")
chequear("df vacío", nrow(excluir_pruebas(.LOG_VACIO())) == 0 &&
         calcular_metricas(.LOG_VACIO())$n_mensajes == 0)

cat(sprintf("\n%d ok, %d fallas\n", ok, fallos))
if (fallos > 0) quit(status = 1)
