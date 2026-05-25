# Tutor de R · Estación R

ShinyApp con un tutor de IA para alumnos del curso **Introducción a R**. Acompaña
fuera de clase con método **socrático calibrado** (guía sin regalar la solución),
en español rioplatense, alineado al currículo (tidyverse + EPH) y a la
bibliografía del curso.

Hecho por [Estación R](https://estacion-r.com) · escuela de datos especializada en R.

## Qué incluye

- **`app/`** — la app del alumno (login por email, chat con el tutor).
- **`app_admin/`** — dashboard de analytics de uso para el equipo docente.
- **`tools/`** — auditor pedagógico (LLM-as-judge) y suites de test.
- **`app/prompts/`** — los system prompts del tutor (versionados).

## Stack

- [Shiny](https://shiny.posit.co/) + [shinychat](https://posit-dev.github.io/shinychat/) + [bslib](https://rstudio.github.io/bslib/)
- [ellmer](https://ellmer.tidyverse.org/) como cliente LLM
- **Modelo primario:** Google Gemini 2.5 Flash · **fallback:** Groq Llama 3.3 70B
- Persistencia de logs (opcional): Google Sheets vía [googlesheets4](https://googlesheets4.tidyverse.org/)

## Correr localmente

```r
# 1. Copiá la plantilla de config y completá los emails autorizados
#    cp app/config.example.yml app/config.yml   (editá la allowlist)
# 2. Asegurate de tener GOOGLE_API_KEY (y GROQ_API_KEY para el fallback) en ~/.Renviron
# 3. Desde la raíz del proyecto:
shiny::runApp("app/")        # app del alumno
shiny::runApp("app_admin/")  # dashboard de analytics (staff)
```

> Lanzá R desde la raíz del proyecto, no desde `app/`: existe un `app/.Renviron`
> que, si arrancás R adentro, tapa al `~/.Renviron` y la API key no se ve.

## Deploy en Posit Connect Cloud

La app es autocontenida (`app/` con `manifest.json`). Se publica desde este repo
seleccionando `app/app.R` como archivo primario. Los secretos y la configuración
van como **variables de entorno** en la UI de Connect Cloud (no se commitean):

| Variable | Para qué |
|----------|----------|
| `GOOGLE_API_KEY` | Modelo primario (Gemini) |
| `GROQ_API_KEY` | Modelo de fallback (Groq) |
| `TUTOR_EMAILS` | Allowlist de alumnos (emails separados por coma) |
| `TUTOR_LOG_SHEET_ID` | Id de la Google Sheet donde persistir el log (opcional) |
| `GOOGLE_SA_JSON` | JSON de la service account con acceso a esa Sheet (opcional) |

Sin `TUTOR_LOG_SHEET_ID`/`GOOGLE_SA_JSON`, la app loguea solo a un archivo local
efímero. Con ellas, espeja cada evento a la Sheet para que el dashboard y el
auditor sobrevivan a los reinicios.

## Privacidad

Las conversaciones se registran (90 días) para mejorar el tutor; hay un aviso
explícito en el login y en la guía del alumno. La allowlist de emails y los
secretos nunca se commitean (van por variables de entorno).

## Licencia

© Estación R. Materiales educativos de uso interno del curso.
