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
- **Modelo primario:** `glm-5.2` en Ollama Cloud · **respaldo:** `glm-5.3`, también en Ollama Cloud con la misma `OLLAMA_API_KEY` (dentro de la suscripción; no hay ningún proveedor externo a ella). Si el principal falla al iniciar o a mitad de la respuesta, la sesión pasa al respaldo con su historial; ver `ESTADO.md`
- Persistencia de logs (opcional): Google Sheet vía Apps Script web app (escritura) + [googlesheets4](https://googlesheets4.tidyverse.org/) (lectura del dashboard)

## Correr localmente

```r
# 1. Copiá la plantilla de config y completá los emails autorizados
#    cp app/config.example.yml app/config.yml   (editá la allowlist)
# 2. Asegurate de tener OLLAMA_API_KEY en ~/.Renviron
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
| `OLLAMA_API_KEY` | Clave de Ollama Cloud: sirve para el modelo principal (`glm-5.2`) y el respaldo (`glm-5.3`) |
| `TUTOR_EMAILS` | Allowlist de alumnos (emails separados por coma) |
| `TUTOR_LOG_WEBHOOK_URL` | URL del Apps Script web app que persiste el log a la Sheet (opcional) |
| `TUTOR_LOG_TOKEN` | Secreto compartido que valida ese Apps Script (opcional) |
| `TUTOR_ID_SALT` | Sal secreta para derivar `alumna_id` del email (opcional; sin ella la columna queda vacía). Generar con `openssl rand -hex 16`, guardarla en un gestor de contraseñas y no cambiarla |
| `TUTOR_COHORTE` | Etiqueta de cohorte que se anota en cada evento del log (opcional; default `intro-r-s2-2026`) |

Sin `TUTOR_LOG_WEBHOOK_URL`/`TUTOR_LOG_TOKEN`, la app loguea solo a un archivo
local efímero. Con ellas, espeja cada evento (vía POST a un Apps Script pegado a
la Sheet) para que el dashboard y el auditor sobrevivan a los reinicios. El
script vive en [`tools/apps-script-logger.gs`](tools/apps-script-logger.gs).
El script escribe **por nombre de encabezado** (fila 1 de la Sheet): para sumar una
columna basta agregar el encabezado con el nombre del campo de `.evento_payload`
(`app/registrar.R`). Cada evento registra, además de ts/email/session_id: `model`,
`prompt_version` (versión + hash del system prompt), `cohorte`, `turno`, `pregunta`,
`respuesta`, `feedback` (👍/👎 de la alumna por respuesta), `alumna_id`,
`latencia_primer_token_ms`, `latencia_total_ms`, `fallback` y `error` (por turno).
El log crudo es la fuente de verdad (append-only). De él se deriva, en R, la tabla
de interacciones (una fila por turno: `app_admin/interacciones.R`; export sin emails con
`Rscript tools/exportar-interacciones.R`). La cohorte se reetiqueta en esa tabla con un
mapeo email → cohorte (pestaña `cohortes` de la misma Sheet, columnas `email`, `cohorte`,
`nota`; en local, `app_admin/cohortes.csv`, gitignorado, ver `cohortes.example.csv`); la
original queda en `cohorte_registrada`. Tests: `Rscript tools/test-registrar.R`,
`tools/test-interacciones.R` y `tools/test-metricas.R`.
Se usa Apps Script en vez de una service account porque la org bloquea las
claves de SA.

## Privacidad

Las conversaciones se registran y se acumulan, sin plazo de borrado, para mejorar
el tutor; a pedido de una alumna se borran las suyas. Hay un aviso explícito en el
login y en la guía del alumno. Para analizar y compartir se usa `alumna_id`, un id
seudónimo derivado del email (HMAC con una sal secreta en la env var `TUTOR_ID_SALT`,
nunca en el repo; si la sal cambia, cambian todos los ids). La allowlist de emails y los
secretos nunca se commitean (van por variables de entorno).

## Licencia

© Estación R. Materiales educativos de uso interno del curso.
