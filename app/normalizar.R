# Normalización determinística de respuestas del fallback (Groq/Llama).
#
# Corrige mecánicamente lo que el modelo de fallback rompe del v3.1 y que NO
# depende del juicio del modelo: dialecto rioplatense (tuteo → voseo) y pipe
# magrittr (%>% → nativo |>). Se aplica solo a las respuestas de Groq · Gemini
# ya cumple, así que sobre su salida sería un no-op.

# Tuteo castellano → voseo rioplatense (presente indicativo + pronombre).
# Las formas castellanas no coinciden con identificadores de R, así que el
# reemplazo es seguro incluso si caen dentro de un bloque de código.
.REEMPLAZOS_VOSEO <- c(
  "puedes"    = "podés",
  "tienes"    = "tenés",
  "haces"     = "hacés",
  "quieres"   = "querés",
  "debes"     = "debés",
  "sabes"     = "sabés",
  "necesitas" = "necesitás",
  "entiendes" = "entendés",
  "dices"     = "decís",
  "pones"     = "ponés",
  "eres"      = "sos",
  "tú"        = "vos"
)

normalizar_rioplatense <- function(texto) {
  if (length(texto) != 1 || is.na(texto) || !nzchar(texto)) return(texto)

  # Pipe magrittr → nativo (solo aparece en código R).
  texto <- gsub("%>%", "|>", texto, fixed = TRUE)

  for (cast in names(.REEMPLAZOS_VOSEO)) {
    vos <- .REEMPLAZOS_VOSEO[[cast]]
    # (*UCP) hace que \b respete límites de palabra Unicode (necesario para "tú").
    texto <- gsub(sprintf("(*UCP)\\b%s\\b", cast), vos, texto, perl = TRUE)
    Cast <- paste0(toupper(substr(cast, 1, 1)), substring(cast, 2))
    Vos  <- paste0(toupper(substr(vos, 1, 1)),  substring(vos, 2))
    texto <- gsub(sprintf("(*UCP)\\b%s\\b", Cast), Vos, texto, perl = TRUE)
  }

  texto
}
