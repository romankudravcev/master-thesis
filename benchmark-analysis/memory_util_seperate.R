# ============================================================
# R-Skript: Memory Usage Plots - 2x4 Grid mit dynamischer Legende
# ============================================================

# 1. Libraries
library(jsonlite)
library(dplyr)
library(ggplot2)
library(purrr)
library(lubridate)
library(patchwork)
library(viridis)
library(cowplot)

# ============================================================
# 2. Configuration
# ============================================================

base_path <- "/Users/romankudravcev/Desktop/master-thesis/benchmark-analysis/results"

output_path <- "/Users/romankudravcev/Desktop/master-thesis/benchmark-analysis/plots"

# Definitionen
databases <- c("postgres", "mongo")
db_types <- c("operator", "stateful")
connectivity_tools <- c("submariner", "skupper", "linkerd")
cluster_types <- c("origin", "target")

db_labels <- c("PostgreSQL", "MongoDB")
type_labels <- c("Operator", "Stateful")
conn_labels <- c("Submariner", "Skupper", "Linkerd")

# Farben für die drei Linien pro Plot
line_colors <- c("Idle" = "#2E86AB", 
                 "Clustershift" = "#A23B72", 
                 "Selected Tool" = "#F18F01")

# FESTE ACHSENLIMITS für alle Plots
FIXED_MEMORY_MAX <- 4000    # Alle Y-Achsen gehen von 0 bis 50%
FIXED_TIME_MAX <- 600  # Alle X-Achsen gehen von 0 bis 600s

# PDF Einstellungen
PDF_WIDTH <- 16   # Breite in Zoll
PDF_HEIGHT <- 10  # Höhe in Zoll
PDF_DPI <- 300    # Auflösung

# ============================================================
# 3. Output-Verzeichnis erstellen
# ============================================================

if(!dir.exists(output_path)) {
  dir.create(output_path, recursive = TRUE)
  cat("Output-Verzeichnis erstellt:", output_path, "\n")
}

# ============================================================
# 4-8. [Gleiche Funktionen wie vorher - nicht geändert]
# ============================================================

get_idle_files <- function(cluster_type, db, db_type) {
  if(cluster_type == "origin") {
    file.path(base_path, "idle_origin", paste0(db,"_",db_type), 
              paste0("idle_",db,"_",db_type,"_util_", 1:3, ".json"))
  } else {
    file.path(base_path, "idle_target", 
              paste0("run", 1:3, ".json"))
  }
}

get_migration_files <- function(db, db_type, conn_tool, reroute_tool, cluster_type) {
  actual_reroute <- ifelse(reroute_tool == "selected_tool", conn_tool, reroute_tool)
  db_full <- paste0(db, "_", db_type)
  
  file.path(base_path, 
            conn_tool, 
            paste0(db_full, "_", actual_reroute),
            paste0(conn_tool, "_", db_full, "_", actual_reroute, "_util_", cluster_type, "_", 1:3, ".json"))
}

process_file <- function(filepath) {
  if(!file.exists(filepath)) {
    return(NULL)
  }
  
  tryCatch({
    df <- fromJSON(filepath)
    
    required_cols <- c("timestamp", "memory_usage")
    if(!all(required_cols %in% colnames(df))) {
      return(NULL)
    }
    
    # Zeitstempel verarbeiten
    df$timestamp <- substr(df$timestamp, 1, 19)
    df$timestamp <- as.POSIXct(df$timestamp, format = "%Y-%m-%dT%H:%M:%S", tz = "UTC")
    
    if(all(is.na(df$timestamp))) {
      return(NULL)
    }
    
    # Convert memory usage from bytes to MB
    df$memory_usage_mb <- df$memory_usage / (1024^2)
    
    start_time <- min(df$timestamp, na.rm = TRUE)
    df <- df %>% 
      mutate(time_index_raw = as.numeric(difftime(timestamp, start_time, units = "secs"))) %>%
      mutate(time_index = ceiling(time_index_raw)) %>%  # Always round UP to next second!
      arrange(time_index) %>%
      filter(time_index <= 600, !is.na(memory_usage_mb)) %>%  # Note: <= instead of < since we're ceiling
      # Group by ceiling time_index and sum memory usage across nodes
      group_by(time_index) %>%
      summarise(cluster_memory_usage_mb = sum(memory_usage_mb, na.rm = TRUE), .groups = 'drop') %>%
      select(time_index, cluster_memory_usage_mb)
    
    return(df)
  }, error = function(e) {
    return(NULL)
  })
}

process_group <- function(files, label) {
  if(length(files) == 0) {
    return(NULL)
  }
  
  all_runs <- map(files, process_file) %>% compact()
  
  if(length(all_runs) == 0) {
    return(NULL)
  }
  
  # Auf gleiche Länge trimmen
  min_length <- min(map_int(all_runs, nrow))
  if(min_length == 0) return(NULL)
  
  all_runs <- map(all_runs, ~ head(.x, min_length))
  
  # Kombinieren und mitteln
  combined <- bind_rows(all_runs, .id = "run")
  averaged <- combined %>% 
    group_by(time_index) %>% 
    summarise(cluster_memory_usage_mb = mean(cluster_memory_usage_mb, na.rm = TRUE), .groups = "drop") %>%
    mutate(migration_type = label)
  
  return(averaged)
}

# ============================================================
# MODIFIZIERTE Datensammlung mit spezifischem Tool-Namen
# ============================================================

collect_data_for_combination <- function(db, db_type, conn_tool, cluster_type) {
  # Idle Daten
  idle_files <- get_idle_files(cluster_type, db, db_type)
  idle_data <- process_group(idle_files, "Idle")
  
  # Migration mit Clustershift
  clustershift_files <- get_migration_files(db, db_type, conn_tool, "clustershift", cluster_type)
  clustershift_data <- process_group(clustershift_files, "Clustershift")
  
  # Migration mit Selected Tool (= connectivity tool)
  # WICHTIG: Hier verwenden wir den spezifischen Tool-Namen
  tool_name <- conn_labels[match(conn_tool, connectivity_tools)]  # Submariner, Skupper, oder Linkerd
  selected_files <- get_migration_files(db, db_type, conn_tool, "selected_tool", cluster_type)
  selected_data <- process_group(selected_files, tool_name)
  
  # Alle Daten kombinieren
  all_data <- list(idle_data, clustershift_data, selected_data) %>% 
    compact() %>% 
    bind_rows()
  
  return(all_data)
}

# ============================================================
# MODIFIZIERTE Plot-Funktion mit dynamischen Farben
# ============================================================

create_subplot <- function(db, db_type, conn_tool, cluster_type) {
  data <- collect_data_for_combination(db, db_type, conn_tool, cluster_type)
  
  # Einfacher Titel - nur Origin/Target
  title <- paste0(toupper(substring(cluster_type, 1, 1)), substring(cluster_type, 2))
  
  # DYNAMISCHE FARBEN: Tool-spezifische Farbe für das jeweilige Tool
  tool_name <- conn_labels[match(conn_tool, connectivity_tools)]
  dynamic_colors <- c("Idle" = "#2E86AB", 
                      "Clustershift" = "#A23B72")
  dynamic_colors[tool_name] <- "#F18F01"  # Orange für das spezifische Tool
  
  if(is.null(data) || nrow(data) == 0) {
    ggplot() + 
      annotate("text", x = FIXED_TIME_MAX/2, y = FIXED_MEMORY_MAX/2, 
               label = "No data", size = 3) +
      labs(title = title, x = "Time (s)", y = "Memory (MB)") +
      xlim(0, FIXED_TIME_MAX) +
      ylim(0, FIXED_MEMORY_MAX) +
      theme_minimal() +
      theme(
        axis.text = element_text(size = 8),
        axis.title = element_text(size = 9),
        plot.title = element_text(size = 10, hjust = 0.5),
        plot.margin = margin(5, 5, 5, 5)
      )
  } else {
    ggplot(data, aes(x = time_index, y = cluster_memory_usage_mb, color = migration_type)) +
      geom_line(linewidth = 0.8) +
      scale_color_manual(values = dynamic_colors, name = "Type") +
      labs(x = "Time (s)", y = "Memory (MB)", title = title) +
      xlim(0, FIXED_TIME_MAX) +
      ylim(0, FIXED_MEMORY_MAX) +
      theme_minimal() +
      theme(
        axis.text = element_text(size = 16),
        axis.title = element_text(size = 16),
        plot.title = element_text(size = 16, hjust = 0.5, face = "bold"),
        legend.position = "none",
        plot.margin = margin(5, 5, 5, 5),
        panel.grid.major = element_line(color = "grey90", size = 0.3),
        panel.grid.minor = element_line(color = "grey95", size = 0.2)
      )
  }
}

create_connectivity_tool_grid <- function(conn_tool) {
  cat("Erstelle Grid für:", conn_tool, "\n")
  
  plots <- list()
  
  # PostgreSQL Plots (Zeile 1)
  plots[[1]] <- create_subplot("postgres", "operator", conn_tool, "origin")
  plots[[2]] <- create_subplot("postgres", "operator", conn_tool, "target")
  plots[[3]] <- create_subplot("postgres", "stateful", conn_tool, "origin")
  plots[[4]] <- create_subplot("postgres", "stateful", conn_tool, "target")
  
  # MongoDB Plots (Zeile 2)
  plots[[5]] <- create_subplot("mongo", "operator", conn_tool, "origin")
  plots[[6]] <- create_subplot("mongo", "operator", conn_tool, "target")
  plots[[7]] <- create_subplot("mongo", "stateful", conn_tool, "origin")
  plots[[8]] <- create_subplot("mongo", "stateful", conn_tool, "target")
  
  # Grid Layout: 2 Zeilen × 4 Spalten
  grid <- wrap_plots(plots, nrow = 2, ncol = 4)
  
  return(grid)
}

# ============================================================
# MODIFIZIERTE Legende-Funktion mit spezifischem Tool-Namen
# ============================================================

create_legend_plot <- function(conn_tool) {
  # Tool-spezifischen Namen holen
  tool_name <- conn_labels[match(conn_tool, connectivity_tools)]
  
  # Dummy-Daten für ALLE drei Kategorien erstellen
  dummy_data <- data.frame(
    time_index = rep(1:3, 3),  # 3 Zeitpunkte für jede Kategorie
    cluster_memory_usage_mb = rep(c(10, 20, 30), 3),  # Verschiedene Y-Werte
    migration_type = rep(c("Idle", "Clustershift", tool_name), each = 3)
  )
  
  # Faktoren in der richtigen Reihenfolge definieren
  dummy_data$migration_type <- factor(dummy_data$migration_type, 
                                      levels = c("Idle", "Clustershift", tool_name))
  
  # DYNAMISCHE FARBEN für dieses spezifische Tool
  dynamic_colors <- c("Idle" = "#2E86AB", 
                      "Clustershift" = "#A23B72")
  dynamic_colors[tool_name] <- "#F18F01"
  
  legend_plot <- ggplot(dummy_data, aes(x = time_index, y = cluster_memory_usage_mb, color = migration_type)) +
    geom_line(linewidth = 1) +
    scale_color_manual(values = dynamic_colors,
                       name = "",
                       breaks = c("Idle", "Clustershift", tool_name)) +
    theme_void() +
    theme(legend.position = "bottom",
          legend.text = element_text(size = 16, margin = margin(l = 15, r = 15)), # Add margin to text
          legend.title = element_text(size = 16, face = "bold"),
          legend.margin = margin(t = 10),
          legend.key.width = unit(2, "cm"),    # Make legend keys wider
          legend.key.height = unit(0.5, "cm")) + # Control height
    guides(color = guide_legend(override.aes = list(linewidth = 2, alpha = 1)))
  
  # Nur die Legende extrahieren
  legend <- get_legend(legend_plot)
  return(legend)
}

create_column_headers <- function() {
  ggplot() + 
    annotate("text", x = 0.325, y = 0.5, label = "Operator", size = 6, fontface = "bold") +
    annotate("text", x = 0.825, y = 0.5, label = "Stateful", size = 6, fontface = "bold") +
    coord_cartesian(xlim = c(0, 1), ylim = c(0, 1)) +
    theme_void() +
    theme(plot.margin = margin(5, 5, 5, 5))
}

create_row_labels <- function() {
  ggplot() + 
    annotate("text", x = 0.5, y = 0.75, label = "PostgreSQL", 
             size = 5, fontface = "bold", angle = 90, hjust = 0.5) +
    annotate("text", x = 0.5, y = 0.25, label = "MongoDB", 
             size = 5, fontface = "bold", angle = 90, hjust = 0.5) +
    coord_cartesian(xlim = c(0, 1), ylim = c(0, 1)) +
    theme_void() +
    theme(plot.margin = margin(5, 5, 5, 5))
}

# ============================================================
# MODIFIZIERTE finale Plot-Funktion
# ============================================================

create_final_plot <- function(conn_tool) {
  # Komponenten erstellen
  main_grid <- create_connectivity_tool_grid(conn_tool)
  legend <- create_legend_plot(conn_tool)
  column_headers <- create_column_headers()
  row_labels <- create_row_labels()
  
  # Grid mit Row Labels kombinieren
  with_row_labels <- plot_grid(
    row_labels, main_grid,
    ncol = 2,
    rel_widths = c(0.08, 0.92)
  )
  
  # Column Header hinzufügen
  with_headers <- plot_grid(
    column_headers, with_row_labels,
    ncol = 1,
    rel_heights = c(0.06, 0.94)
  )
  
  # Legende hinzufügen
  final_plot <- plot_grid(
    with_headers, legend,
    ncol = 1,
    rel_heights = c(0.9, 0.1)
  )
  
  return(final_plot)
}

# ============================================================
# 10. MAIN: Plots erstellen und als PDF speichern
# ============================================================

cat("=== ERSTELLE UND SPEICHERE PLOTS FÜR ALLE CONNECTIVITY TOOLS ===\n")
cat("Output-Pfad:", output_path, "\n")
cat("PDF-Einstellungen:", PDF_WIDTH, "x", PDF_HEIGHT, "Zoll bei", PDF_DPI, "DPI\n")
cat("Verwende feste Achsenlimits: X = 0-", FIXED_TIME_MAX, "s, Y = 0-", FIXED_MEMORY_MAX, "%\n\n")

for(conn_tool in connectivity_tools) {
  tool_name <- conn_labels[match(conn_tool, connectivity_tools)]
  cat("--- Erstelle Plot für", conn_tool, "(", tool_name, ") ---\n")
  
  # Finalen Plot erstellen
  final_plot <- create_final_plot(conn_tool)
  
  # PDF Dateiname
  pdf_filename <- paste0("memory_usage_analysis_", conn_tool, ".pdf")
  pdf_filepath <- file.path(output_path, pdf_filename)
  
  # Als PDF speichern
  cat("Speichere als PDF:", pdf_filepath, "\n")
  
  tryCatch({
    ggsave(
      filename = pdf_filepath,
      plot = final_plot,
      width = PDF_WIDTH,
      height = PDF_HEIGHT,
      units = "in",
      dpi = PDF_DPI,
      device = "pdf"
    )
    cat("✓ PDF erfolgreich gespeichert\n")
  }, error = function(e) {
    cat("✗ Fehler beim Speichern der PDF:", e$message, "\n")
  })
  
  # Plot auch anzeigen (optional)
  print(final_plot)
  
  cat("Plot für", conn_tool, "erstellt und gespeichert\n\n")
}

# ============================================================
# 11. Zusammenfassung
# ============================================================

cat("=== ZUSAMMENFASSUNG ===\n")
cat("3 separate PDF-Dateien erstellt mit TOOL-SPEZIFISCHER Legende:\n")
for(conn_tool in connectivity_tools) {
  tool_name <- conn_labels[match(conn_tool, connectivity_tools)]
  pdf_filename <- paste0("memory_usage_analysis_", conn_tool, ".pdf")
  cat("- ", pdf_filename, " → Legende: Idle, Clustershift,", tool_name, "\n")
}
cat("\nAlle PDFs gespeichert in:", output_path, "\n")
cat("PDF-Größe:", PDF_WIDTH, "x", PDF_HEIGHT, "Zoll (", PDF_DPI, "DPI)\n")
cat("Alle Y-Achsen: 0 bis", FIXED_MEMORY_MAX, "% MEMORY Usage\n")
cat("Alle X-Achsen: 0 bis", FIXED_TIME_MAX, "s Zeit\n")
cat("\nDie PDFs mit tool-spezifischen Legenden sind bereit! 📊\n")

# ============================================================
# 12. BONUS: Kombinierte PDF (optional)
# ============================================================

cat("\n=== ERSTELLE KOMBINIERTE PDF (OPTIONAL) ===\n")

combined_pdf_path <- file.path(output_path, "memory_usage_analysis_all_tools.pdf")
cat("Erstelle kombinierte PDF mit allen 3 Tools:", combined_pdf_path, "\n")

tryCatch({
  pdf(combined_pdf_path, width = PDF_WIDTH, height = PDF_HEIGHT)
  
  for(conn_tool in connectivity_tools) {
    tool_name <- conn_labels[match(conn_tool, connectivity_tools)]
    cat("Füge", tool_name, "zur kombinierten PDF hinzu...\n")
    final_plot <- create_final_plot(conn_tool)
    print(final_plot)
  }
  
  dev.off()
  cat("✓ Kombinierte PDF erfolgreich erstellt\n")
}, error = function(e) {
  cat("✗ Fehler beim Erstellen der kombinierten PDF:", e$message, "\n")
})

cat("Fertig! 🎉\n")