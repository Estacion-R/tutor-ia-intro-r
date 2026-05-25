# clasificar.R · clasificación liviana de consultas del tutor (issue #2 analytics)
#
# Enfoque (a) del issue #2: regex de keywords sobre el texto del alumno.
# Costo cero, sin llamada extra al LLM. Accuracy ~70%, suficiente para ver la
# distribución de tipos de consulta por cohorte. Si la cohorte real muestra que
# falla mucho, se evalúa el enfoque (b) (clasificador LLM en pipeline).
#
# Funciones puras y determinísticas → testeables sin levantar Shiny
# (ver tools/test-clasificar.R).

# Normaliza para matchear: minúsculas + sin acentos (el alumno no siempre
# escribe tildes). ü→u, ñ→n para no perder matches.
.normalizar_match <- function(texto) {
  chartr("áéíóúüñ", "aeiouun", tolower(texto))
}

# Keywords por categoría. El ORDEN de este vector = prioridad (primer match
# gana), porque una consulta puede disparar varias. Cada patrón es regex PCRE
# sobre el texto normalizado (sin acentos) → se escribe sin tildes.
.PATRONES_CATEGORIA <- c(
  error     = "\\berror\\b|no anda|no me anda|no funciona|no corre|no me corre|\\bfalla\\b|\\bfallo\\b|warning|no aparece|me tira|se rompe|not found|could not find|unexpected|no me sale",
  tp        = "\\btp\\b|trabajo practico|consigna|entrega|\\bparcial\\b|\\bexamen\\b",
  ejercicio = "ejercicio|ejercitar|practicar|practica|para practicar",
  sintaxis  = "como se escribe|como se usa|como se llama|sintaxis|que argumentos|argumentos de|como es la sintaxis",
  concepto  = "que es|que significa|no entiendo|diferencia entre|para que sirve|explicame|explicar|explica|concepto|no me queda claro|que hace"
)

# Clasifica el texto del alumno en {error, tp, ejercicio, sintaxis, concepto, otro}.
clasificar_consulta <- function(texto) {
  if (length(texto) != 1 || is.na(texto) || !nzchar(trimws(texto))) {
    return("otro")
  }
  t <- .normalizar_match(texto)
  for (cat in names(.PATRONES_CATEGORIA)) {
    if (grepl(.PATRONES_CATEGORIA[[cat]], t, perl = TRUE)) return(cat)
  }
  "otro"
}

# Señal de "dame la respuesta / hacelo por mí" para la métrica de pedagogía.
# Es independiente de la categoría (ej. "haceme el TP" es tp + pide_respuesta).
.PATRON_PIDE_RESPUESTA <- paste0(
  "dame la respuesta|decime la respuesta|dame el codigo|dame la solucion|",
  "pasame el codigo|pasame la solucion|hacelo por mi|haceme el|haceme la|",
  "resolvelo|resolveme|la solucion completa|el codigo completo|",
  "no tengo tiempo|decime ya|dame ya"
)

# TRUE si el alumno está pidiendo la solución hecha (insistencia anti-pedagógica).
detectar_pedido_respuesta <- function(texto) {
  if (length(texto) != 1 || is.na(texto) || !nzchar(trimws(texto))) return(FALSE)
  grepl(.PATRON_PIDE_RESPUESTA, .normalizar_match(texto), perl = TRUE)
}
