library(shiny)
library(bslib)
library(shinychat)
library(ellmer)
library(yaml)
library(jsonlite)
library(promises)

# brand.yml es un Suggests de bslib que se carga dinámicamente al usar
# bs_theme(brand = ...). Lo declaramos explícito para que rsconnect lo capture
# en el manifest y Connect Cloud lo instale (si no, falla al iniciar la app).
requireNamespace("brand.yml", quietly = TRUE)

# La alumna no debe ver mensajes técnicos crudos (ej. errores de red de un stream
# cortado): shiny los reemplaza por un texto genérico.
options(shiny.sanitize.errors = TRUE)

# --- Configuración ---
# Emails autorizados: de la env var TUTOR_EMAILS (CSV) en hosting (Connect Cloud),
# o de config.yml en local. config.yml NO se commitea (tiene emails reales) → en
# un repo público la allowlist vive como secreto de entorno.
leer_emails_autorizados <- function() {
  env <- Sys.getenv("TUTOR_EMAILS", "")
  if (nzchar(env)) return(tolower(trimws(strsplit(env, ",")[[1]])))
  if (file.exists("config.yml")) {
    return(tolower(yaml::read_yaml("config.yml")$emails_autorizados))
  }
  character(0)
}
emails_autorizados <- leer_emails_autorizados()

# System prompt = v3.1 + bibliografía del curso inyectada (Sprint 3).
source("armar_prompt.R")
source("clasificar.R")  # clasificación liviana de consultas (analytics, issue #2)
source("registrar.R")   # sink opcional de log a Google Sheet (persistencia en la nube)

# Activa el espejo a Google Sheet si están las env vars (hosting efímero).
# Inerte en local → la app loguea solo al archivo. Ver registrar.R.
init_sheets_logging()
system_prompt <- armar_system_prompt(
  prompt_path = "prompts/tutor-general-v3.1.md",
  biblio_path = "prompts/bibliografia.yml"
)

# Modelo primario: glm-5.2 vía Ollama Cloud Pro. Rollback 2026-09-15 desde
# glm-5.3: eval F5 dio 5 ok/1 menor/1 moderada (vs 7/7 ok de glm-5.2) con
# una regresión pedagógica real (tutor explicando en vez de guiar
# socráticamente) y latencia P50 20-30s vs ~5s de glm-5.2. Ver ESTADO.md.
# Pineado explícito para no caer en defaults del cliente que cambien con
# updates.
OLLAMA_MODEL    <- "glm-5.2"
# Overridable por env var SOLO para pruebas locales (servidor Ollama simulado);
# en producción no se setea y apunta a Ollama Cloud.
OLLAMA_BASE_URL <- Sys.getenv("OLLAMA_BASE_URL", "https://ollama.com")
# Respaldo cuando glm-5.2 falla (modelo caído, 401, corte a mitad de respuesta):
# glm-5.3, también en Ollama Cloud con la misma OLLAMA_API_KEY (dentro de la
# suscripción, sin costo extra). Evaluado el 2026-09-15: 5 ok / 1 menor /
# 1 moderada / 0 grave, con respuestas de 20-30 s; para una emergencia alcanza.
# Decisión de Pablo (06/10/2026): NO se usa ningún proveedor fuera de la
# suscripción de Ollama (se sacó Gemini de la cadena por la regla de costo).
OLLAMA_FALLBACK_MODEL <- "glm-5.3"
log_path     <- "tutor.log"

# Metadatos que se anotan en cada evento del log para analizar y mejorar el
# tutor (solo registro: no cambian el comportamiento del chat).
# - PROMPT_VERSION: versión del prompt + hash corto del system prompt completo
#   (prompt + bibliografía), así cualquier edición queda distinguible en la Sheet.
# - COHORTE: etiqueta de la cohorte (override con la env var TUTOR_COHORTE).
#   Cohorte e335c127 del sistema de cursos = Intro a R S2 2026.
PROMPT_VERSION <- paste0(
  "v3.1-", substr(rlang::hash(system_prompt), 1, 8)
)
COHORTE <- {
  c_env <- Sys.getenv("TUTOR_COHORTE", "")
  if (nzchar(c_env)) c_env else "intro-r-s2-2026"
}
# Id de modelo que responde, según el proveedor activo. `provider` es "ollama"
# (principal) u "ollama_respaldo" (glm-5.3). Los logs previos al 07/10 pueden
# traer "gemini" (ya no se usa).
modelo_de <- function(proveedor) {
  switch(proveedor %||% "", ollama = OLLAMA_MODEL,
         ollama_respaldo = OLLAMA_FALLBACK_MODEL, NA_character_)
}

# --- Logging mínimo (F3, expandido en F4 · session_id en #2) ---
# Escribe una línea JSON por evento. Falla en silencio si no puede escribir
# para no romper la UX del alumno. `session_id` (Shiny session$token) permite
# agrupar eventos en sesiones para el dashboard de analytics (app_admin/).
log_event <- function(type, email = NA_character_, details = NULL,
                      session_id = NA_character_) {
  tryCatch({
    evt <- list(
      ts         = format(Sys.time(), "%Y-%m-%dT%H:%M:%OS3", tz = "UTC"),
      type       = type,
      email      = email,
      session_id = session_id,
      alumna_id      = alumna_id_de(email),
      prompt_version = PROMPT_VERSION,
      cohorte        = COHORTE
    )
    if (!is.null(details)) evt$details <- details
    cat(jsonlite::toJSON(evt, auto_unbox = TRUE, null = "null"), "\n",
        file = log_path, append = TRUE, sep = "")
    # Espejo persistente a Google Sheet (no-op si el sink está inactivo).
    append_evento_sheet(evt)
  }, error = function(e) invisible(NULL))
}

# Chat de ellmer contra Ollama Cloud para un modelo dado.
crear_chat_ollama <- function(modelo, system_prompt) {
  ellmer::chat_ollama(
    base_url      = OLLAMA_BASE_URL,
    credentials   = function() list(
      Authorization = paste("Bearer", Sys.getenv("OLLAMA_API_KEY"))
    ),
    model         = modelo,
    system_prompt = system_prompt
  )
}

# Crea el chat inicial con glm-5.2; si falla (chat_ollama chequea el servidor al
# crearse), prueba con el respaldo glm-5.3. Si ambos fallan devuelve chat = NULL
# (la app reintenta al primer mensaje). Devuelve list(chat, provider).
crear_chat <- function(system_prompt, email = NA_character_,
                       session_id = NA_character_) {
  tryCatch(
    {
      chat <- crear_chat_ollama(OLLAMA_MODEL, system_prompt)
      log_event("chat_init", email = email, session_id = session_id,
                details = list(provider = "ollama", model = modelo_de("ollama")))
      list(chat = chat, provider = "ollama")
    },
    error = function(e) {
      log_event("ollama_init_failed", email = email, session_id = session_id,
                details = list(mensaje = conditionMessage(e), error = TRUE))
      tryCatch(
        {
          chat <- crear_chat_ollama(OLLAMA_FALLBACK_MODEL, system_prompt)
          log_event("chat_init", email = email, session_id = session_id,
                    details = list(provider = "ollama_respaldo",
                                   model = modelo_de("ollama_respaldo"),
                                   fallback = TRUE))
          list(chat = chat, provider = "ollama_respaldo")
        },
        error = function(e2) {
          log_event("fallback_failed", email = email, session_id = session_id,
                    details = list(mensaje = conditionMessage(e2), error = TRUE))
          list(chat = NULL, provider = NA_character_)
        }
      )
    }
  )
}

# Envuelve el stream async de ellmer (un "generador" que devuelve una promesa por
# cada trozo de texto) para dos cosas:
# 1) anotar cuándo llega el primer trozo (latencia al primer token, la que percibe
#    la alumna);
# 2) manejar un corte: si el principal falla mientras se lee (típicamente a mitad
#    de respuesta), se emite un aviso y se continúa con el modelo de respaldo EN EL
#    MISMO stream. Un segundo chat_append() tras un stream fallido queda colgado en
#    shinychat, y un generador de coro con tryCatch + dos for anidados tampoco
#    continuaba (ambos probados en local), por eso se arma a mano con promesas.
# - `marca`: environment con t_primer / t_primer_respaldo / corte.
# - `respaldo`: función sin argumentos que pasa al respaldo y devuelve su stream
#   (NULL si ya se está en respaldo: el error se propaga).
# shinychat acepta cualquier función con clase "coro_generator_instance" que
# devuelva el próximo trozo (o coro::exhausted()) envuelto en una promesa.
stream_con_respaldo <- function(fuente, marca, respaldo = NULL) {
  estado <- "principal"   # principal -> aviso -> respaldo
  siguiente <- function(...) {
    if (identical(estado, "aviso")) {
      estado <<- "respaldo"
      fuente <<- respaldo()
    }
    promises::then(
      promises::promise_resolve(fuente()),
      onFulfilled = function(chunk) {
        if (!coro::is_exhausted(chunk) && is.character(chunk) && nzchar(chunk)) {
          if (identical(estado, "respaldo")) {
            if (is.null(marca$t_primer_respaldo)) marca$t_primer_respaldo <- Sys.time()
          } else if (is.null(marca$t_primer)) {
            marca$t_primer <- Sys.time()
          }
        }
        chunk
      },
      onRejected = function(e) {
        if (identical(estado, "principal") && !is.null(respaldo)) {
          estado <<- "aviso"
          marca$corte <- conditionMessage(e)
          return("\n\n_Se cortó la respuesta del modelo principal; sigo con el de respaldo (puede tardar un poco más)._\n\n")
        }
        stop(e)
      }
    )
  }
  structure(siguiente, class = c("coro_generator_instance", "function"))
}
ms_desde <- function(t0, t1) {
  if (is.null(t1)) return(NA_integer_)
  as.integer(round(as.numeric(difftime(t1, t0, units = "secs")) * 1000))
}

# --- Plantillas de ayuda (Sprint 4 post-MVP) ---
# Cards clickeables arriba del chat. Al click, copian la plantilla al input
# del shinychat (sin enviar) para que el alumno reemplace los placeholders [X]
# y mande. Corchetes = pendientes a resolver, no texto final.
PLANTILLAS_AYUDA <- list(
  list(
    id     = "ayuda_puntual",
    icono  = "chat-dots",
    titulo = "Tengo una duda puntual",
    texto  = "Tengo una duda puntual: [escribí tu pregunta]"
  ),
  list(
    id     = "ayuda_error",
    icono  = "wrench",
    titulo = "Tengo un error",
    texto  = paste0(
      "Pegué este código y me dio un error:\n\n",
      "```r\n[acá pegá tu código]\n```\n\n",
      "Mensaje de error:\n\n",
      "```\n[acá pegá el mensaje completo]\n```\n\n",
      "¿Qué intenté hacer mal?"
    )
  ),
  list(
    id     = "ayuda_concepto",
    icono  = "lightbulb",
    titulo = "No entiendo un concepto",
    texto  = paste0(
      "No entiendo qué es [concepto o función]. ",
      "¿Me podés dar una explicación con un ejemplo simple usando datos sociales?"
    )
  ),
  list(
    id     = "ayuda_ejercicio",
    icono  = "pencil-square",
    titulo = "Quiero practicar",
    texto  = paste0(
      "¿Me podés dar un ejercicio para practicar [función o tema] usando datos sociales? ",
      "Estoy aprendiendo [contame el nivel: recién arrancando / módulo X / etc]."
    )
  ),
  list(
    id     = "ayuda_mejorar",
    icono  = "stars",
    titulo = "Mejorar mi código",
    texto  = paste0(
      "Mi código funciona pero quiero mejorarlo. ",
      "[Describí qué te suena raro o querés cambiar.]\n\n",
      "```r\n[acá pegá tu código]\n```"
    )
  )
)

# --- UI ---
ui <- page_fillable(
  theme = bslib::bs_theme(brand = "_brand.yml"),

  tags$head(
    tags$style(HTML("
      .login-card {
        max-width: 400px;
        margin: 80px auto;
      }
      .app-header {
        padding: 12px 20px;
        background-color: #FFFFFF;
        color: #191919;
        border-bottom: 2px solid #405BFF;
        display: flex;
        justify-content: space-between;
        align-items: center;
        margin-bottom: 0;
      }
      .app-header h4 { margin: 0; font-size: 1.1rem; font-weight: 500; }
      .app-header .user-email { font-size: 0.85rem; color: #666; }
      .app-header .logout-link { color: #405BFF; margin-left: 8px; text-decoration: none; }
      .app-header .logout-link:hover { color: #1839F4; text-decoration: underline; }
      .disclaimer {
        font-size: 0.8rem;
        color: #666;
        text-align: center;
        padding: 8px;
        background-color: #F7F7F7;
        border-top: 1px solid #EAEAEA;
      }
      .ayuda-cards {
        display: flex;
        flex-wrap: wrap;
        gap: 8px;
        padding: 12px 20px;
        background-color: #F7F7F7;
        border-bottom: 1px solid #EAEAEA;
      }
      .ayuda-cards .ayuda-hint {
        flex-basis: 100%;
        font-size: 0.75rem;
        color: #666;
        margin: 0 0 4px 0;
      }
      .ayuda-card {
        flex: 1 1 180px;
        min-width: 160px;
        background-color: #FFFFFF;
        border: 1px solid #DDE3EE;
        border-radius: 6px;
        padding: 10px 12px;
        cursor: pointer;
        text-align: left;
        color: #191919;
        font-size: 0.85rem;
        transition: all 0.15s;
        display: flex;
        align-items: center;
        gap: 8px;
      }
      .ayuda-card:hover {
        border-color: #405BFF;
        color: #405BFF;
        background-color: #FFFFFF;
        transform: translateY(-1px);
      }
      .ayuda-card .ayuda-icon { color: #405BFF; font-size: 1.1rem; }
      .ayuda-card .ayuda-titulo { font-weight: 500; }
      .feedback-bar {
        display: flex;
        align-items: center;
        justify-content: center;
        gap: 8px;
        padding: 6px 12px;
        font-size: 0.8rem;
        color: #666;
        border-top: 1px solid #EAEAEA;
      }
      .feedback-bar .btn {
        padding: 2px 10px;
        font-size: 0.95rem;
        background: #FFFFFF;
        border: 1px solid #DDE3EE;
        border-radius: 6px;
      }
      .feedback-bar .btn:hover { border-color: #405BFF; }
    "))
  ),

  # --- Login ---
  conditionalPanel(
    condition = "!output.autenticado",
    div(
      class = "login-card",
      card(
        card_header(
          tags$h3("Tutor de R", style = "margin:0;"),
          tags$p("Estación R", style = "margin:0; opacity:0.7; font-size:0.9rem;")
        ),
        card_body(
          tags$p("Ingresá el email con el que te inscribiste al curso."),
          textInput("email", label = NULL, placeholder = "tu@email.com"),
          actionButton("login", "Entrar", class = "btn-primary w-100"),
          uiOutput("login_error"),
          tags$p(
            "Al ingresar aceptás que guardemos tus consultas para mejorar el",
            "tutor. Si querés que borremos las tuyas, escribinos a",
            "estacionr.com@gmail.com y lo hacemos.",
            "No compartas datos personales sensibles.",
            style = "font-size: 0.75rem; color: #666; margin-top: 16px; text-align: center;"
          )
        )
      )
    )
  ),

  # --- Chat (post-login) ---
  conditionalPanel(
    condition = "output.autenticado",
    div(
      class = "app-header",
      tags$h4("Tutor de R — Estación R"),
      div(
        class = "user-email",
        textOutput("email_display", inline = TRUE),
        actionLink("logout", "(salir)", class = "logout-link")
      )
    ),
    div(
      class = "ayuda-cards",
      tags$p(
        class = "ayuda-hint",
        "Escribí tu pregunta directo en el chat de abajo. ",
        "Si no sabés cómo arrancar, tocá una tarjeta y reemplazá los ",
        tags$code("[corchetes]"), " antes de mandar."
      ),
      lapply(PLANTILLAS_AYUDA, function(p) {
        actionButton(
          inputId = p$id,
          label = tagList(
            span(class = "ayuda-icon", bsicons::bs_icon(p$icono)),
            span(class = "ayuda-titulo", p$titulo)
          ),
          class = "ayuda-card"
        )
      })
    ),
    chat_ui(
      id = "chat",
      messages = "**¡Hola!** Soy tu tutor de R del curso. ¿En qué andás?"
    ),
    # Feedback por respuesta: aparece cuando hay una respuesta sin calificar.
    conditionalPanel(
      condition = "output.pedir_feedback",
      div(
        class = "feedback-bar",
        span("¿Te sirvió esta respuesta?"),
        actionButton("fb_up", "\U0001F44D", class = "btn-sm",
                     `aria-label` = "Me sirvió"),
        actionButton("fb_down", "\U0001F44E", class = "btn-sm",
                     `aria-label` = "No me sirvió")
      )
    ),
    div(
      class = "disclaimer",
      "Este tutor usa IA y puede cometer errores.",
      "Verificá siempre el código en RStudio."
    )
  ),

  fillable_mobile = TRUE
)

# --- Server ---
server <- function(input, output, session) {

  # ID de sesión: agrupa todos los eventos de este alumno en una sesión para
  # las métricas de analytics (app_admin/). Único por pestaña/sesión Shiny.
  sid <- session$token

  # Estado de autenticación
  autenticado <- reactiveVal(FALSE)
  email_usuario <- reactiveVal("")

  output$autenticado <- reactive(autenticado())
  outputOptions(output, "autenticado", suspendWhenHidden = FALSE)

  output$email_display <- renderText(email_usuario())

  # Login
  observeEvent(input$login, {
    email <- tolower(trimws(input$email))
    if (email %in% emails_autorizados) {
      autenticado(TRUE)
      email_usuario(email)
      log_event("login_ok", email = email, session_id = sid)
    } else {
      log_event("login_fail", email = email, session_id = sid)
      output$login_error <- renderUI(
        tags$p(
          "Email no registrado en el curso. ",
          "Si creés que es un error, escribí a estacionr.com@gmail.com",
          style = "color: #dc3545; font-size: 0.9rem; margin-top: 10px;"
        )
      )
    }
  })

  # Logout
  observeEvent(input$logout, {
    autenticado(FALSE)
    email_usuario("")
    session$reload()
  })

  # Plantillas de ayuda (Sprint 4): click en card → copia plantilla al input
  # del chat sin enviar. focus=TRUE permite al alumno editar los [placeholders]
  # de inmediato.
  for (p in PLANTILLAS_AYUDA) {
    local({
      pid   <- p$id
      ptext <- p$texto
      observeEvent(input[[pid]], {
        shinychat::update_chat_user_input(
          id    = "chat",
          value = ptext,
          focus = TRUE
        )
        log_event("plantilla_click", email = email_usuario(), session_id = sid,
                  details = list(plantilla = pid))
      })
    })
  }

  # Chat LLM (se crea al autenticarse, uno por sesión).
  # Ollama glm-5.2 primario · glm-5.3 (Ollama) como respaldo automático.
  chat     <- reactiveVal(NULL)
  provider <- reactiveVal(NULL)

  # Número de turno dentro de la sesión (1 = primera consulta). `turno_respondido`
  # es el último turno con respuesta completa; `turno_calificado`, el último con
  # 👍/👎. El feedback se asocia a `turno_respondido`.
  turno            <- reactiveVal(0L)
  turno_respondido <- reactiveVal(0L)
  turno_calificado <- reactiveVal(0L)
  # Último modelo/proveedor que respondió (el proveedor puede cambiar por fallback).
  modelo_respondido    <- reactiveVal(NA_character_)
  proveedor_respondido <- reactiveVal(NA_character_)

  output$pedir_feedback <- reactive(turno_respondido() > turno_calificado())
  outputOptions(output, "pedir_feedback", suspendWhenHidden = FALSE)

  registrar_feedback <- function(valor) {
    t <- isolate(turno_respondido())
    if (t <= isolate(turno_calificado())) return(invisible(NULL))
    log_event("feedback", email = isolate(email_usuario()), session_id = sid,
              details = list(
                provider = isolate(proveedor_respondido()),
                model    = isolate(modelo_respondido()),
                turno    = t,
                feedback = valor
              ))
    turno_calificado(t)
    showNotification("¡Gracias por tu opinión!", duration = 2, type = "message")
  }
  observeEvent(input$fb_up,   registrar_feedback("up"))
  observeEvent(input$fb_down, registrar_feedback("down"))

  observeEvent(autenticado(), {
    if (autenticado()) {
      res <- crear_chat(system_prompt, email = email_usuario(), session_id = sid)
      chat(res$chat)
      provider(res$provider)
    }
  })

  # Crea el chat de respaldo (glm-5.3), le hereda el historial y deja la sesión en
  # respaldo (provider). Un stream fallido deja en ellmer el turno del usuario y
  # un turno parcial del asistente (a veces con texto cortado): se descartan,
  # porque la consulta se vuelve a enviar y no debe quedar duplicada. Una vez en
  # respaldo, la sesión sigue en respaldo.
  pasar_a_respaldo <- function(email) {
    chat_viejo <- isolate(chat())
    chat_nuevo <- crear_chat_ollama(OLLAMA_FALLBACK_MODEL, system_prompt)
    tryCatch({
      turnos <- chat_viejo$get_turns()
      repeat {
        n <- length(turnos)
        if (n == 0) break
        ult <- turnos[[n]]
        if (any(grepl("Partial", class(ult))) || identical(ult@role, "user")) {
          turnos <- turnos[-n]
        } else break
      }
      chat_nuevo$set_turns(turnos)
    }, error = function(e) invisible(NULL))
    chat(chat_nuevo)
    provider("ollama_respaldo")
    log_event("stream_fallback_to_respaldo", email = email, session_id = sid,
              details = list(model = OLLAMA_FALLBACK_MODEL, turno = isolate(turno())))
    chat_nuevo
  }

  # Falla SÍNCRONA del principal (al iniciar la respuesta): pasa al respaldo y
  # reintenta la consulta. Si ya estaba en respaldo, avisa a la alumna.
  reintentar_con_respaldo <- function(user_input, email) {
    if (!identical(isolate(provider()), "ollama")) {
      chat_append("chat",
        "El servicio está saturado en este momento. Probá en un minuto.")
      return(invisible(NULL))
    }
    tryCatch(
      {
        pasar_a_respaldo(email)
        chat_append("chat",
          "_El modelo principal no respondió; sigo con el de respaldo (puede tardar un poco más)._")
        enviar_mensaje(user_input, email, reintento = TRUE)
      },
      error = function(e2) {
        log_event("fallback_failed", email = email, session_id = sid,
                  details = list(turno = isolate(turno()), error = TRUE,
                                 mensaje = conditionMessage(e2)))
        chat_append("chat",
          "Hubo un problema técnico atendiendo tu consulta. Probá en un minuto.")
      }
    )
    invisible(NULL)
  }

  # Envía el input al LLM activo (chat() reactiveVal), loguea input y respuesta.
  # chat_append() devuelve una promesa; usamos promises::then() para capturar
  # el contenido completo de la respuesta cuando termine el stream.
  # `reintento = TRUE` (reenvío tras pasar al respaldo) conserva el mismo turno.
  enviar_mensaje <- function(user_input, email, reintento = FALSE) {
    if (!reintento) turno(isolate(turno()) + 1L)
    # Se capturan antes del stream: los callbacks de la promesa corren después.
    t        <- isolate(turno())
    prov     <- isolate(provider())
    modl     <- modelo_de(prov)
    log_event("chat_message", email = email, session_id = sid, details = list(
      provider       = prov,
      model          = modl,
      turno          = t,
      reintento      = if (reintento) TRUE else NULL,
      fallback       = !identical(prov, "ollama"),
      categoria      = clasificar_consulta(user_input),
      pide_respuesta = detectar_pedido_respuesta(user_input),
      input_chars    = nchar(user_input),
      input_text     = user_input
    ))

    # Ambos modelos (glm-5.2 y glm-5.3) soportan streaming nativo y siguen el
    # v3.1 con suficiente fidelidad → ruta común, sin normalizer ni refuerzo.
    t0       <- Sys.time()
    marca    <- new.env(parent = emptyenv())
    # Estado de la respuesta en curso: cambia si el stream se corta y se pasa al
    # respaldo (todo dentro del mismo stream, ver stream_con_respaldo).
    marca$prov     <- prov
    marca$modl     <- modl
    marca$chat_obj <- isolate(chat())
    respaldo <- if (identical(prov, "ollama")) function() {
      log_event("chat_response_rejected", email = email, session_id = sid,
        details = list(provider = prov, model = modl, turno = t, error = TRUE,
                       reason = marca$corte))
      nuevo <- pasar_a_respaldo(email)
      marca$prov     <- "ollama_respaldo"
      marca$modl     <- modelo_de("ollama_respaldo")
      marca$chat_obj <- nuevo
      nuevo$stream_async(user_input)
    }
    stream   <- stream_con_respaldo(marca$chat_obj$stream_async(user_input), marca, respaldo)
    appended <- chat_append("chat", stream)
    promises::then(
      appended,
      onFulfilled = function(value) {
        last <- marca$chat_obj$last_turn()
        log_event("chat_response", email = email, session_id = sid, details = list(
          provider        = marca$prov,
          model           = marca$modl,
          turno           = t,
          fallback        = !identical(marca$prov, "ollama"),
          # Si hubo corte y respaldo, el "primer token" es el del principal (lo que
          # vio la alumna primero); el total incluye el tiempo del respaldo.
          latencia_primer_token_ms = ms_desde(t0, marca$t_primer %||% marca$t_primer_respaldo),
          latencia_total_ms        = ms_desde(t0, Sys.time()),
          response_chars  = nchar(last@text),
          response_text   = last@text
        ))
        proveedor_respondido(marca$prov)
        modelo_respondido(marca$modl)
        turno_respondido(t)
      },
      onRejected = function(reason) {
        # Falló también el respaldo (o ya se estaba en respaldo): no hay más a
        # dónde pasar. shinychat muestra un aviso genérico (errores saneados).
        log_event("chat_response_rejected", email = email, session_id = sid,
          details = list(
            provider = marca$prov,
            model    = marca$modl,
            turno    = t,
            error    = TRUE,
            reason   = conditionMessage(reason)
          ))
        # shinychat ya mostró su aviso genérico (en inglés); se suma uno propio.
        chat_append("chat",
          "Hubo un problema técnico atendiendo tu consulta. Probá en un minuto.")
      }
    )
    invisible(appended)
  }

  # Si Ollama falla al iniciar la respuesta, pasamos al respaldo y reintentamos
  # el último input (con el historial previo).
  observeEvent(input$chat_user_input, {
    user_input <- input$chat_user_input
    email      <- email_usuario()

    # Si el chat no pudo crearse al autenticarse (Ollama caído), se reintenta ahora.
    if (is.null(chat())) {
      res <- crear_chat(system_prompt, email = email, session_id = sid)
      chat(res$chat)
      provider(res$provider)
    }
    if (is.null(chat())) {
      chat_append("chat",
        "El servicio no está disponible en este momento. Probá en un minuto.")
      return(invisible(NULL))
    }

    tryCatch(
      enviar_mensaje(user_input, email),
      error = function(e) {
        log_event("stream_failed", email = email, session_id = sid, details = list(
          provider = isolate(provider()),
          model    = modelo_de(isolate(provider())),
          turno    = isolate(turno()),
          error    = TRUE,
          mensaje  = conditionMessage(e)
        ))
        reintentar_con_respaldo(user_input, email)
      }
    )
  })
}

shinyApp(ui, server)
