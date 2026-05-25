# Reporte semanal de auditoría pedagógica · tutor_ia_intro_r
#
# Lee `app/auditoria.log` de los últimos N días y produce:
# 1) Markdown completo en `_gestion/auditorias-tutor/YYYY-WNN.md` (vive en
#    Pablo/Estación R/_gestion/ relativo a este proyecto, dos niveles arriba).
# 2) Resumen ejecutivo posteado a Discord #pedagogía (vía tools/post-pedagogia.py).
#
# Uso:
#   Rscript tools/reportar-auditoria.R              # ventana: últimos 7 días
#   Rscript tools/reportar-auditoria.R 14           # últimos 14 días
#   Rscript tools/reportar-auditoria.R 7 --no-post  # markdown sin postear a Discord

suppressPackageStartupMessages({
  library(jsonlite)
})

`%||%` <- function(a, b) if (is.null(a) || (length(a) == 1 && is.na(a))) b else a

AUDIT_LOG_PATH     <- "app/auditoria.log"
TUTOR_LOG_PATH     <- "app/tutor.log"
REPORTES_DIR       <- "../../../_gestion/auditorias-tutor"
POST_HELPER_PY     <- "tools/post-pedagogia.py"

# --- Helpers ---------------------------------------------------------------

cargar_jsonl <- function(path) {
  if (!file.exists(path)) return(list())
  lineas <- readLines(path, warn = FALSE)
  out <- lapply(lineas, function(l) {
    tryCatch(jsonlite::fromJSON(l, simplifyVector = FALSE),
             error = function(e) NULL)
  })
  Filter(Negate(is.null), out)
}

parsear_ts <- function(ts) {
  # Formato ISO "2026-05-17T14:05:50.305"
  as.POSIXct(ts, format = "%Y-%m-%dT%H:%M:%OS", tz = "UTC")
}

semana_iso <- function(ts) {
  format(ts, "%G-W%V")
}

# --- Reporte ---------------------------------------------------------------

generar_reporte <- function(dias = 7) {
  audits <- cargar_jsonl(AUDIT_LOG_PATH)
  cutoff <- Sys.time() - as.difftime(dias, units = "days")

  recientes <- Filter(function(a) {
    ts <- parsear_ts(a$audited_at)
    !is.na(ts) && ts >= cutoff
  }, audits)

  n_total <- length(recientes)
  if (n_total == 0) {
    return(list(
      n_total = 0,
      markdown = sprintf(
        "# Auditoría tutor IA · ventana %d días\n\n_Sin turnos auditados en el período._\n\nÚltimo update: %s",
        dias, format(Sys.time(), "%Y-%m-%d %H:%M %Z")
      ),
      resumen_discord = sprintf(
        "📊 **Auditoría tutor IA · %d días**\n\nSin actividad en el período (0 turnos auditados).",
        dias
      )
    ))
  }

  # Severidades
  sev <- vapply(recientes,
                function(a) a$dictamen$severidad %||% "?", character(1))
  dist_sev <- table(sev)

  # Red flags
  flags <- unlist(lapply(recientes,
                         function(a) a$dictamen$red_flags %||% character(0)))
  top_flags <- if (length(flags) > 0) head(sort(table(flags), decreasing = TRUE), 5) else NULL

  # Comentarios destacados (uno por severidad no-ok)
  ejemplos <- list()
  for (s in c("grave", "moderada", "menor")) {
    candidato <- Filter(function(a) identical(a$dictamen$severidad, s), recientes)
    if (length(candidato) > 0) {
      a <- candidato[[1]]
      ejemplos[[s]] <- list(
        input = a$input,
        coment = a$dictamen$comentario %||% ""
      )
    }
  }

  # Alumnos únicos
  emails <- unique(vapply(recientes, function(a) a$email %||% "?", character(1)))

  # Providers usados
  providers <- table(vapply(recientes,
                            function(a) a$provider %||% "?", character(1)))

  # --- Markdown completo ---
  md_lines <- c(
    sprintf("# Auditoría tutor IA · ventana %d días", dias),
    "",
    sprintf("**Generado:** %s",
            format(Sys.time(), "%Y-%m-%d %H:%M %Z")),
    sprintf("**Cobertura:** %s a %s",
            format(cutoff, "%Y-%m-%d"),
            format(Sys.time(), "%Y-%m-%d")),
    "",
    "## Volumen",
    "",
    sprintf("- Turnos auditados: **%d**", n_total),
    sprintf("- Alumnos únicos: **%d**", length(emails)),
    sprintf("- Providers del tutor: %s",
            paste(sprintf("%s (%d)", names(providers), as.integer(providers)),
                  collapse = ", ")),
    "",
    "## Distribución de severidades",
    "",
    paste(sprintf("- **%s**: %d (%.0f%%)",
                  names(dist_sev), as.integer(dist_sev),
                  100 * as.integer(dist_sev) / n_total),
          collapse = "\n"),
    ""
  )

  if (!is.null(top_flags) && length(top_flags) > 0) {
    md_lines <- c(md_lines, "## Top red flags",
                  "",
                  paste(sprintf("- `%s` (%d)",
                                names(top_flags), as.integer(top_flags)),
                        collapse = "\n"),
                  "")
  }

  if (length(ejemplos) > 0) {
    md_lines <- c(md_lines, "## Ejemplos representativos por severidad", "")
    for (s in names(ejemplos)) {
      md_lines <- c(md_lines,
                    sprintf("### Severidad: %s", s),
                    "",
                    sprintf("**Input del alumno:** %s",
                            substr(ejemplos[[s]]$input, 1, 200)),
                    "",
                    sprintf("**Dictamen:** %s", ejemplos[[s]]$coment),
                    "")
    }
  }

  md_lines <- c(md_lines,
                "## Baseline F5 (referencia, 2026-05-17)",
                "",
                "Suite sintética: 5 ok / 2 menor / 0 moderada / 0 grave.",
                "Drift = severidad de hoy peor que baseline F5.",
                "")

  markdown <- paste(md_lines, collapse = "\n")

  # --- Resumen Discord (max ~1900 chars) ---
  emojis <- c(ok = "✅", menor = "🟡", moderada = "🟠",
              grave = "🔴", parse_error = "❓")
  sev_str <- paste(sprintf("%s %s: %d",
                           emojis[names(dist_sev)] %||% "·",
                           names(dist_sev), as.integer(dist_sev)),
                   collapse = " · ")

  discord_lines <- c(
    sprintf("📊 **Auditoría tutor IA · ventana %d días**", dias),
    "",
    sprintf("**Turnos:** %d · **Alumnos únicos:** %d",
            n_total, length(emails)),
    sprintf("**Distribución:** %s", sev_str)
  )

  if (!is.null(top_flags) && length(top_flags) > 0) {
    discord_lines <- c(discord_lines, "",
                       "**Top red flags:**",
                       paste(sprintf("- `%s` (%d)",
                                     names(top_flags),
                                     as.integer(top_flags)),
                             collapse = "\n"))
  }

  if (length(ejemplos) > 0) {
    discord_lines <- c(discord_lines, "")
    peor <- if ("grave" %in% names(ejemplos)) "grave"
            else if ("moderada" %in% names(ejemplos)) "moderada"
            else "menor"
    e <- ejemplos[[peor]]
    discord_lines <- c(discord_lines,
                       sprintf("**Ejemplo (%s):** _%s_",
                               peor, substr(e$coment, 1, 200)))
  }

  discord_lines <- c(discord_lines, "",
                     "_Detalle completo en `_gestion/auditorias-tutor/`._")

  resumen_discord <- paste(discord_lines, collapse = "\n")

  list(
    n_total = n_total,
    markdown = markdown,
    resumen_discord = resumen_discord,
    semana = semana_iso(Sys.time())
  )
}

postear_discord <- function(texto) {
  if (!file.exists(POST_HELPER_PY)) {
    message("No encuentro ", POST_HELPER_PY, " · skip Discord")
    return(invisible(FALSE))
  }
  res <- tryCatch(
    {
      out <- system2("python3", args = POST_HELPER_PY,
                     input = texto, stdout = TRUE, stderr = TRUE)
      cat(paste(out, collapse = "\n"), "\n")
      TRUE
    },
    error = function(e) {
      message("postear_discord falló: ", conditionMessage(e))
      FALSE
    }
  )
  invisible(res)
}

# --- Modo script -----------------------------------------------------------

if (!interactive()) {
  args <- commandArgs(trailingOnly = TRUE)
  dias <- if (length(args) >= 1 && !is.na(as.numeric(args[[1]])))
            as.numeric(args[[1]]) else 7
  do_post <- !("--no-post" %in% args)

  cat(sprintf("Reporte: últimos %d días · post Discord: %s\n",
              dias, ifelse(do_post, "sí", "no")))

  r <- generar_reporte(dias = dias)
  cat(sprintf("Turnos en ventana: %d\n", r$n_total))

  # Guardar markdown
  dir.create(REPORTES_DIR, recursive = TRUE, showWarnings = FALSE)
  out_path <- file.path(REPORTES_DIR, paste0(r$semana, ".md"))
  writeLines(r$markdown, out_path)
  cat(sprintf("Markdown guardado en: %s\n", out_path))

  if (do_post) {
    cat("Posteando a Discord #pedagogía...\n")
    postear_discord(r$resumen_discord)
  } else {
    cat("--no-post · resumen Discord:\n\n")
    cat(r$resumen_discord, "\n")
  }
}
