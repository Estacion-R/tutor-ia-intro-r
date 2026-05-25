# Tests de clasificar_consulta() y detectar_pedido_respuesta() (issue #2)
# Uso:  Rscript tools/test-clasificar.R   (desde la raíz del proyecto)
#
# No usa testthat para no agregar dependencia: harness mínimo con conteo.

source("app/clasificar.R")

# --- Casos de categoría ---------------------------------------------------
casos_categoria <- list(
  list(txt = "Error: object 'datos' not found",             esp = "error"),
  list(txt = "no me anda el filter",                         esp = "error"),
  list(txt = "me tira un warning raro",                      esp = "error"),
  list(txt = "Haceme el TP",                                 esp = "tp"),
  list(txt = "no entiendo la consigna del trabajo practico", esp = "tp"),
  list(txt = "dame un ejercicio de filter y select",         esp = "ejercicio"),
  list(txt = "quiero practicar joins",                       esp = "ejercicio"),
  list(txt = "como se escribe summarise",                    esp = "sintaxis"),
  list(txt = "que argumentos toma mutate",                   esp = "sintaxis"),
  list(txt = "no entiendo qué es un data frame",             esp = "concepto"),
  list(txt = "para qué sirve el pipe",                       esp = "concepto"),
  list(txt = "explicame group_by",                           esp = "concepto"),
  list(txt = "hola, buenas",                                 esp = "otro"),
  list(txt = "",                                             esp = "otro"),
  list(txt = NA_character_,                                  esp = "otro")
)

# --- Casos de pedido de respuesta -----------------------------------------
casos_pide <- list(
  list(txt = "dame la respuesta ya",      esp = TRUE),
  list(txt = "Haceme el TP",              esp = TRUE),
  list(txt = "decime ya no tengo tiempo", esp = TRUE),
  list(txt = "pasame el codigo completo", esp = TRUE),
  list(txt = "como se escribe summarise", esp = FALSE),
  list(txt = "no entiendo los joins",     esp = FALSE)
)

# --- Harness --------------------------------------------------------------
ok <- 0L; fail <- 0L

cat("== clasificar_consulta() ==\n")
for (c in casos_categoria) {
  got <- clasificar_consulta(c$txt)
  pass <- identical(got, c$esp)
  if (pass) ok <- ok + 1L else fail <- fail + 1L
  cat(sprintf("  [%s] %-45s -> %-9s (esp: %s)\n",
              if (pass) "OK" else "XX",
              substr(ifelse(is.na(c$txt), "<NA>", c$txt), 1, 45),
              got, c$esp))
}

cat("\n== detectar_pedido_respuesta() ==\n")
for (c in casos_pide) {
  got <- detectar_pedido_respuesta(c$txt)
  pass <- identical(got, c$esp)
  if (pass) ok <- ok + 1L else fail <- fail + 1L
  cat(sprintf("  [%s] %-45s -> %-5s (esp: %s)\n",
              if (pass) "OK" else "XX",
              substr(c$txt, 1, 45), got, c$esp))
}

cat(sprintf("\nResultado: %d OK / %d FAIL\n", ok, fail))
if (fail > 0) quit(status = 1)
