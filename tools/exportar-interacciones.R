# Exporta la tabla de interacciones (una fila por turno) a CSV, SIN emails.
# Deriva del log crudo (la Sheet si hay TUTOR_LOG_SHEET_ID; si no, app/tutor.log).
# Uso (desde la raíz del repo):
#   TUTOR_LOG_SHEET_ID=<id> Rscript tools/exportar-interacciones.R [--con-pruebas]
# Salida: tools/output/interacciones-<fecha>.csv (carpeta gitignorada).
#
# OJO: aunque no lleve emails, `pregunta` y `respuesta` son texto libre de las
# alumnas y pueden contener datos personales. Compartir solo con quien corresponda.
suppressPackageStartupMessages(source("app_admin/metricas.R"))

args <- commandArgs(trailingOnly = TRUE)
sheet_id <- Sys.getenv("TUTOR_LOG_SHEET_ID", "")
df <- if (nzchar(sheet_id)) cargar_log_sheet(sheet_id) else cargar_log("app/tutor.log")
if (!"--con-pruebas" %in% args) df <- excluir_pruebas(df)

inter <- armar_interacciones(df, incluir_email = FALSE)
dir.create("tools/output", showWarnings = FALSE, recursive = TRUE)
out <- file.path("tools/output", sprintf("interacciones-%s.csv", format(Sys.Date())))
utils::write.csv(inter, out, row.names = FALSE, na = "", fileEncoding = "UTF-8")
cat(sprintf("%d interacciones → %s\n", nrow(inter), out))
