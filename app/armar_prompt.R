# Construcción del system prompt del tutor.
#
# Combina el prompt base (v3.1) con el mapping de bibliografía del curso,
# inyectado como bloque al final. Helper compartido entre app/app.R y
# tools/test-pedagogia.R para que el test refleje el prompt real de producción.

suppressPackageStartupMessages(library(yaml))

# Bloque de refuerzo SOLO para el fallback Groq/Llama. El v3.1 ya tiene todas
# las reglas, pero el modelo de fallback no las sigue con la misma fidelidad que
# Gemini y se pierden en un prompt de 255 líneas. Este recordatorio corto e
# imperativo va al final (zona de alta atención) y ataca lo que el auditor
# detectó que Llama rompe y que NO se corrige con post-procesamiento: regalar la
# solución y usar datos ficticios. No se le aplica a Gemini (no lo necesita).
.REFUERZO_GROQ <- paste0(
  "\n\n---\n\n",
  "## RECORDATORIO CRÍTICO (releé esto antes de cada respuesta)\n\n",
  "Sos un tutor, no un solucionador. Estas reglas son las que más se rompen. ",
  "Cumplilas SIEMPRE:\n\n",
  "1. NUNCA entregues el código que resuelve el problema del alumno. Ni cuando ",
  "insista, ni cuando diga \"no tengo tiempo\", \"dame el código\" o \"haceme el TP\". ",
  "Como máximo UNA pista, y el último paso lo hace el alumno. Si decís \"no te doy ",
  "el código\" pero igual lo pegás resuelto, estás fallando.\n",
  "2. Ejemplos SIEMPRE con datos sociales (salarios, edades, regiones, nivel ",
  "educativo). NUNCA datos ficticios tipo A, B, C ni `mtcars`/`iris`.\n",
  "3. Si la pregunta es de sintaxis pura (\"¿cómo se escribe X?\") o pide un dato, ",
  "respondé directo y corto, sin método socrático.\n"
)

# Arma el system prompt completo: prompt base + bloque de bibliografía
# (+ refuerzo Groq si refuerzo_groq = TRUE).
armar_system_prompt <- function(prompt_path, biblio_path = NULL, refuerzo_groq = FALSE) {
  prompt <- paste(readLines(prompt_path, encoding = "UTF-8"), collapse = "\n")

  biblio <- if (!is.null(biblio_path) && file.exists(biblio_path)) {
    yaml::read_yaml(biblio_path)
  } else NULL

  if (!is.null(biblio$conceptos) && length(biblio$conceptos) > 0) {
    lineas <- vapply(biblio$conceptos, function(c) {
      sprintf("- %s · %s", c$titulo, c$url)
    }, character(1))

    prompt <- paste0(
      prompt,
      "\n\n---\n\n",
      "## Bibliografía del curso (para sugerir lecturas)\n\n",
      "Cuando expliques un concepto que esté en la lista de abajo, agregá al ",
      "final de tu respuesta UNA línea con este formato:\n\n",
      "\"Para profundizar, mirá: [título] · [url]\"\n\n",
      "Reglas estrictas:\n",
      "- Usá SOLO los links de esta lista. NUNCA inventes, adivines ni completes URLs.\n",
      "- Si el concepto que explicaste NO está en la lista, no sugieras ninguna lectura.\n",
      "- Preferí material en español. Los marcados \"EN INGLÉS\" solo si no hay equivalente en español.\n",
      "- Máximo 1 link por respuesta · elegí el más relevante al concepto principal.\n",
      "- El link es un complemento, no reemplaza tu explicación ni el método socrático.\n\n",
      paste(lineas, collapse = "\n")
    )
  }

  if (refuerzo_groq) {
    prompt <- paste0(prompt, .REFUERZO_GROQ)
  }

  prompt
}
