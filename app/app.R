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

# Modelo primario: glm-5.2 vía Ollama Cloud Pro (decidido 2026-05-27 tras eval
# F5: 7 ok / 0 menor vs 6 ok / 1 menor del baseline Gemini Flash). Pineado
# explícito para no caer en defaults del cliente que cambien con updates.
OLLAMA_MODEL    <- "glm-5.2"
OLLAMA_BASE_URL <- "https://ollama.com"
# Fallback cuando Ollama falla (rate limit, quota Pro agotada, network):
# Gemini 2.5 Flash, el modelo que era primario hasta 2026-05-27. Validado en
# producción semanas previas; con un fallback conocido reducimos riesgo durante
# la transición a glm-5.2.
GEMINI_MODEL <- "gemini-2.5-flash"
log_path     <- "tutor.log"

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
      session_id = session_id
    )
    if (!is.null(details)) evt$details <- details
    cat(jsonlite::toJSON(evt, auto_unbox = TRUE, null = "null"), "\n",
        file = log_path, append = TRUE, sep = "")
    # Espejo persistente a Google Sheet (no-op si el sink está inactivo).
    append_evento_sheet(evt)
  }, error = function(e) invisible(NULL))
}

# Crea el chat inicial con Ollama (glm-5.2), cae a Gemini si Ollama falla.
# Devuelve list(chat, provider) para que el server sepa con qué proveedor está.
crear_chat <- function(system_prompt, email = NA_character_,
                       session_id = NA_character_) {
  tryCatch(
    {
      chat <- ellmer::chat_ollama(
        base_url      = OLLAMA_BASE_URL,
        credentials   = function() list(
          Authorization = paste("Bearer", Sys.getenv("OLLAMA_API_KEY"))
        ),
        model         = OLLAMA_MODEL,
        system_prompt = system_prompt
      )
      log_event("chat_init", email = email, session_id = session_id,
                details = list(provider = "ollama"))
      list(chat = chat, provider = "ollama")
    },
    error = function(e) {
      log_event("ollama_init_failed", email = email, session_id = session_id,
                details = conditionMessage(e))
      chat <- ellmer::chat_google_gemini(model = GEMINI_MODEL,
                                         system_prompt = system_prompt)
      log_event("chat_init", email = email, session_id = session_id,
                details = list(provider = "gemini", fallback = TRUE))
      list(chat = chat, provider = "gemini")
    }
  )
}

# --- Plantillas de ayuda (Sprint 4 post-MVP) ---
# Cards clickeables arriba del chat. Al click, copian la plantilla al input
# del shinychat (sin enviar) para que el alumno reemplace los placeholders [X]
# y mande. Corchetes = pendientes a resolver, no texto final.
PLANTILLAS_AYUDA <- list(
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
            "Al ingresar aceptás que tus conversaciones se guardan 90 días",
            "para mejorar el tutor. No compartas datos personales sensibles.",
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
        "¿No sabés cómo arrancar? Tocá una tarjeta y reemplazá los ",
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
  # Ollama glm-5.2 primario · Gemini 2.5 Flash fallback automático.
  chat     <- reactiveVal(NULL)
  provider <- reactiveVal(NULL)

  observeEvent(autenticado(), {
    if (autenticado()) {
      res <- crear_chat(system_prompt, email = email_usuario(), session_id = sid)
      chat(res$chat)
      provider(res$provider)
    }
  })

  # Envía el input al LLM activo (chat() reactiveVal), loguea input y respuesta.
  # chat_append() devuelve una promesa; usamos promises::then() para capturar
  # el contenido completo de la respuesta cuando termine el stream.
  enviar_mensaje <- function(user_input, email) {
    log_event("chat_message", email = email, session_id = sid, details = list(
      provider       = provider(),
      categoria      = clasificar_consulta(user_input),
      pide_respuesta = detectar_pedido_respuesta(user_input),
      input_chars    = nchar(user_input),
      input_text     = user_input
    ))

    # Ambos providers (ollama, gemini) soportan streaming nativo y siguen el
    # v3.1 con suficiente fidelidad → ruta común, sin normalizer ni refuerzo.
    stream   <- chat()$stream_async(user_input)
    appended <- chat_append("chat", stream)
    promises::then(
      appended,
      onFulfilled = function(value) {
        last <- chat()$last_turn()
        log_event("chat_response", email = email, session_id = sid, details = list(
          provider        = provider(),
          response_chars  = nchar(last@text),
          response_text   = last@text
        ))
      },
      onRejected = function(reason) {
        # En caso de rejection async, el tryCatch del observer ya intentó
        # el fallback. Acá solo dejamos rastro de que la promesa se rechazó.
        log_event("chat_response_rejected", email = email, session_id = sid,
          details = list(
            provider = provider(),
            reason   = conditionMessage(reason)
          ))
      }
    )
    invisible(appended)
  }

  # Stream con fallback: si Ollama falla a mitad de conversación, recreamos
  # chat con Gemini y reintentamos el último input.
  # Nota: en el fallback se pierde el historial del intercambio actual.
  # TODO: preservar turns previos (ellmer::Chat$get_turns/append_turns) cuando
  # se valide la semántica en práctica.
  observeEvent(input$chat_user_input, {
    req(chat())
    user_input <- input$chat_user_input
    email      <- email_usuario()

    tryCatch(
      enviar_mensaje(user_input, email),
      error = function(e) {
        log_event("stream_failed", email = email, session_id = sid, details = list(
          provider = provider(),
          error    = conditionMessage(e)
        ))

        if (identical(provider(), "ollama")) {
          tryCatch(
            {
              chat_nuevo <- ellmer::chat_google_gemini(
                model         = GEMINI_MODEL,
                system_prompt = system_prompt
              )
              chat(chat_nuevo)
              provider("gemini")
              log_event("stream_fallback_to_gemini", email = email, session_id = sid)

              # Reintento con Gemini usando el mismo helper:
              # vuelve a loguear chat_message + chat_response.
              enviar_mensaje(user_input, email)
            },
            error = function(e2) {
              log_event("fallback_failed", email = email, session_id = sid,
                        details = conditionMessage(e2))
              chat_append("chat",
                "Hubo un problema técnico atendiendo tu consulta. Probá en un minuto.")
            }
          )
        } else {
          chat_append("chat",
            "El servicio está saturado en este momento. Probá en un minuto.")
        }
      }
    )
  })
}

shinyApp(ui, server)
