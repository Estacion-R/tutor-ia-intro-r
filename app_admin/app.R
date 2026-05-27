# Dashboard de analytics del Tutor de R · Estación R (issue #2)
#
# App Shiny SEPARADA de la del alumno (app/). Lee app/tutor.log en modo solo
# lectura y muestra métricas de adopción, engagement, tipo de consulta, calidad
# y pedagogía. Acceso restringido al staff (Pablo + docente) por allowlist.
#
# Correr:  shiny::runApp("app_admin/")   (desde la raíz del proyecto)
#
# La lógica de lectura/cálculo vive en metricas.R (pura, testeable sin Shiny).

library(shiny)
library(bslib)
library(ggplot2)
library(scales)
library(reactable)
library(yaml)

source("metricas.R")

# --- Configuración ---
# Staff autorizado: de la env var TUTOR_STAFF (CSV) o de config.yml en local.
# config.yml NO se commitea (emails reales).
leer_staff <- function() {
  env <- Sys.getenv("TUTOR_STAFF", "")
  if (nzchar(env)) return(tolower(trimws(strsplit(env, ",")[[1]])))
  if (file.exists("config.yml")) {
    return(tolower(yaml::read_yaml("config.yml")$staff_autorizado))
  }
  character(0)
}
staff_autorizado <- leer_staff()
LOG_PATH         <- "../app/tutor.log"   # log local de la app del alumno (dev)

# Fuente del log: si TUTOR_LOG_SHEET_ID está seteada, lee de la Google Sheet
# persistente (el tutor hosteado escribe ahí); si no, del archivo local.
LOG_SHEET_ID <- Sys.getenv("TUTOR_LOG_SHEET_ID", "")
usar_sheet   <- nzchar(LOG_SHEET_ID)
# Si usar_sheet, googlesheets4 autentica de forma interactiva (login de Google
# del staff) la primera vez que lee la planilla. El dashboard corre local, así
# que el flujo interactivo alcanza; no se usa service account (la org bloquea
# las claves de SA, por eso el tutor escribe vía Apps Script).

# Lee el log de la fuente vigente (planilla o archivo).
leer_log <- function() {
  if (usar_sheet) cargar_log_sheet(LOG_SHEET_ID) else cargar_log(LOG_PATH)
}

# Paleta Estación R para los gráficos
COLOR_AZUL   <- "#405BFF"
COLOR_NEGRO  <- "#191919"
COLOR_GRIS   <- "#F7F7F7"

tema_ggplot <- theme_minimal(base_size = 13) +
  theme(
    panel.grid.minor = element_blank(),
    plot.title       = element_text(face = "bold", size = 13),
    axis.title       = element_text(color = "#666666")
  )

fmt <- function(x, dec = 0, sufijo = "") {
  if (is.null(x) || length(x) == 0 || is.na(x) || is.nan(x)) return("—")
  paste0(formatC(x, format = "f", big.mark = ".", decimal.mark = ",", digits = dec), sufijo)
}

# --- UI ---
ui <- page_fillable(
  theme = bslib::bs_theme(brand = "../app/_brand.yml"),
  tags$head(tags$style(HTML("
    .login-card { max-width: 400px; margin: 80px auto; }
    .dash-header {
      padding: 12px 20px; border-bottom: 2px solid #405BFF;
      display: flex; justify-content: space-between; align-items: center;
    }
    .dash-header h4 { margin: 0; font-weight: 500; }
  "))),

  # --- Login ---
  conditionalPanel(
    condition = "!output.autorizado",
    div(class = "login-card", card(
      card_header(
        tags$h3("Analytics del Tutor", style = "margin:0;"),
        tags$p("Estación R · solo staff", style = "margin:0; opacity:0.7; font-size:0.9rem;")
      ),
      card_body(
        tags$p("Ingresá tu email de staff."),
        textInput("email", label = NULL, placeholder = "tu@email.com"),
        actionButton("login", "Entrar", class = "btn-primary w-100"),
        uiOutput("login_error")
      )
    ))
  ),

  # --- Dashboard (post-login) ---
  conditionalPanel(
    condition = "output.autorizado",
    div(class = "dash-header",
      tags$h4("Analytics del Tutor de R — Estación R"),
      actionLink("logout", "(salir)")
    ),
    layout_sidebar(
      sidebar = sidebar(
        title = "Filtros",
        dateRangeInput("rango", "Rango de fechas",
                       start = Sys.Date() - 30, end = Sys.Date(),
                       separator = " a ", language = "es", weekstart = 1),
        actionButton("recargar", "Recargar log", icon = icon("rotate"),
                     class = "btn-outline-primary btn-sm"),
        tags$hr(),
        tags$p(class = "text-muted",
               style = "font-size:0.78rem;",
               "Fuente: ",
               tags$code(if (usar_sheet) "Google Sheet (persistente)" else "app/tutor.log (local)"),
               ". Las sesiones se cuentan desde que se registra ",
               tags$code("session_id"), " (mayo 2026 en adelante).")
      ),
      uiOutput("sin_datos"),
      layout_columns(
        fill = FALSE,
        value_box("Alumnos únicos", textOutput("vb_alumnos"),
                  showcase = bsicons::bs_icon("people-fill"), theme = "primary"),
        value_box("Sesiones", textOutput("vb_sesiones"),
                  showcase = bsicons::bs_icon("chat-dots-fill")),
        value_box("Mensajes", textOutput("vb_mensajes"),
                  showcase = bsicons::bs_icon("envelope-fill")),
        value_box("Msgs / sesión", textOutput("vb_msgs_sesion"),
                  showcase = bsicons::bs_icon("bar-chart-fill"))
      ),
      layout_columns(
        fill = FALSE,
        value_box("Latencia P50", textOutput("vb_lat_p50"),
                  showcase = bsicons::bs_icon("speedometer2")),
        value_box("Latencia P95", textOutput("vb_lat_p95"),
                  showcase = bsicons::bs_icon("speedometer")),
        value_box("Fallbacks a Groq", textOutput("vb_fallback"),
                  showcase = bsicons::bs_icon("shield-exclamation"), theme = "secondary"),
        value_box("Piden la respuesta", textOutput("vb_pide"),
                  showcase = bsicons::bs_icon("hand-index-thumb"), theme = "secondary")
      ),
      layout_columns(
        card(card_header("Tipo de consulta"), plotOutput("plot_categoria", height = "280px")),
        card(card_header("Mensajes por día"), plotOutput("plot_por_dia", height = "280px"))
      ),
      card(card_header("Actividad por alumno"), reactableOutput("tabla_alumnos"))
    )
  )
)

# --- Server ---
server <- function(input, output, session) {

  autorizado <- reactiveVal(FALSE)
  output$autorizado <- reactive(autorizado())
  outputOptions(output, "autorizado", suspendWhenHidden = FALSE)

  observeEvent(input$login, {
    email <- tolower(trimws(input$email))
    if (email %in% staff_autorizado) {
      autorizado(TRUE)
    } else {
      output$login_error <- renderUI(
        tags$p("Email no autorizado. Este panel es solo para staff.",
               style = "color:#dc3545; font-size:0.9rem; margin-top:10px;")
      )
    }
  })

  observeEvent(input$logout, { autorizado(FALSE); session$reload() })

  # Lee el log al iniciar y en cada click de "Recargar" (planilla o archivo)
  datos <- eventReactive(input$recargar, leer_log(), ignoreNULL = FALSE)

  m <- reactive({
    req(autorizado(), datos())
    calcular_metricas(datos(), input$rango[1], input$rango[2])
  })

  # Aviso cuando no hay mensajes en la ventana
  output$sin_datos <- renderUI({
    req(autorizado())
    if (m()$n_mensajes == 0) {
      div(class = "alert alert-info",
          "Sin mensajes en la ventana seleccionada. ",
          "El log todavía puede estar vacío (sin cohorte activa) o el rango de ",
          "fechas no cubre actividad registrada.")
    }
  })

  # Value boxes
  output$vb_alumnos    <- renderText(fmt(m()$n_alumnos))
  output$vb_sesiones   <- renderText(fmt(m()$n_sesiones))
  output$vb_mensajes   <- renderText(fmt(m()$n_mensajes))
  output$vb_msgs_sesion <- renderText(fmt(m()$msgs_por_sesion, dec = 1))
  output$vb_lat_p50    <- renderText(fmt(m()$lat_p50, dec = 1, sufijo = "s"))
  output$vb_lat_p95    <- renderText(fmt(m()$lat_p95, dec = 1, sufijo = "s"))
  output$vb_fallback   <- renderText(fmt(m()$n_fallback_msgs))
  output$vb_pide       <- renderText({
    paste0(fmt(m()$n_pide), " (", fmt(m()$pct_pide), "%)")
  })

  # Gráfico de tipo de consulta
  output$plot_categoria <- renderPlot({
    d <- m()$df_categoria
    validate(need(nrow(d) > 0, "Sin datos."))
    ggplot(d, aes(x = reorder(categoria, n), y = n)) +
      geom_col(fill = COLOR_AZUL, width = 0.7) +
      geom_text(aes(label = n), hjust = -0.2, size = 4, color = COLOR_NEGRO) +
      coord_flip() +
      labs(x = NULL, y = "Mensajes") +
      expand_limits(y = max(d$n) * 1.1) +
      tema_ggplot
  })

  # Serie temporal de mensajes por día
  output$plot_por_dia <- renderPlot({
    d <- m()$df_por_dia
    validate(need(nrow(d) > 0, "Sin datos."))
    ggplot(d, aes(x = dia, y = n)) +
      geom_col(fill = COLOR_AZUL, width = 0.7) +
      scale_x_date(date_labels = "%d/%m") +
      labs(x = NULL, y = "Mensajes") +
      tema_ggplot
  })

  # Tabla por alumno
  output$tabla_alumnos <- renderReactable({
    d <- m()$df_por_alumno
    validate(need(nrow(d) > 0, "Sin datos."))
    d$ult_actividad <- format(d$ult_actividad, "%Y-%m-%d %H:%M")
    reactable(
      d,
      columns = list(
        email          = colDef(name = "Alumno", minWidth = 200),
        sesiones       = colDef(name = "Sesiones", align = "center"),
        mensajes       = colDef(name = "Mensajes", align = "center"),
        pide_respuesta = colDef(name = "Pidió respuesta", align = "center"),
        ult_actividad  = colDef(name = "Última actividad", minWidth = 150)
      ),
      defaultSorted = list(mensajes = "desc"),
      striped = TRUE, highlight = TRUE, compact = TRUE,
      defaultPageSize = 15
    )
  })
}

shinyApp(ui, server)
