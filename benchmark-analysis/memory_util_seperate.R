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

base_path <- "results"
output_path <- "plots"

# Definitionen
databases <- c("postgres", "mongo")
db_types <- c("operator", "stateful")
connectivity_tools <- c("submariner", "skupper", "linkerd")
cluster_types <- c("origin", "target")

db_labels <- c("PostgreSQL", "MongoDB")
type_labels <- c("Operator", "Stateful")
conn_labels <- c("Submariner", "Skupper", "Linkerd")

line_colors <- c("Idle" = "#2E86AB", 
                 "Clustershift" = "#A23B72", 
                 "Selected Tool" = "#F18F01")

# FESTE ACHSENLIMITS für alle Plots
FIXED_MEMORY_MAX <- 4000
FIXED_TIME_MAX <- 600

# PDF Einstellungen
PDF_WIDTH <- 16
PDF_HEIGHT <- 10
PDF_DPI <- 300

# ============================================================
# 3. Output-Verzeichnis erstellen
# ============================================================

if(!dir.exists(output_path)) {
  dir.create(output_path, recursive = TRUE)
  cat("Output-Verzeichnis erstellt:", output_path, "\n")
}

# ============================================================
# File Handling
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
    
    df$timestamp <- substr(df$timestamp, 1, 19)
    df$timestamp <- as.POSIXct(df$timestamp, format = "%Y-%m-%dT%H:%M:%S", tz = "UTC")
    
    if(all(is.na(df$timestamp))) {
      return(NULL)
    }
    
    df$memory_usage_mb <- df$memory_usage / (1024^2)
    
    start_time <- min(df$timestamp, na.rm = TRUE)
    df <- df %>% 
      mutate(time_index_raw = as.numeric(difftime(timestamp, start_time, units = "secs"))) %>%
      mutate(time_index = ceiling(time_index_raw)) %>%  # Always round UP to next second!
      arrange(time_index) %>%
      filter(time_index <= 600, !is.na(memory_usage_mb)) %>%  # Note: <= instead of < since we're ceiling
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
  
  min_length <- min(map_int(all_runs, nrow))
  if(min_length == 0) return(NULL)
  
  all_runs <- map(all_runs, ~ head(.x, min_length))
  
  combined <- bind_rows(all_runs, .id = "run")
  averaged <- combined %>% 
    group_by(time_index) %>% 
    summarise(cluster_memory_usage_mb = mean(cluster_memory_usage_mb, na.rm = TRUE), .groups = "drop") %>%
    mutate(migration_type = label)
  
  return(averaged)
}

# ============================================================
# 5. Datensammlung
# ============================================================

collect_data_for_combination <- function(db, db_type, conn_tool, cluster_type) {
  # Idle Daten
  idle_files <- get_idle_files(cluster_type, db, db_type)
  idle_data <- process_group(idle_files, "Idle")
  
  # Migration mit Clustershift
  clustershift_files <- get_migration_files(db, db_type, conn_tool, "clustershift", cluster_type)
  clustershift_data <- process_group(clustershift_files, "Clustershift")
  
  # Migration mit Selected Tool (= connectivity tool)
  tool_name <- conn_labels[match(conn_tool, connectivity_tools)]
  selected_files <- get_migration_files(db, db_type, conn_tool, "selected_tool", cluster_type)
  selected_data <- process_group(selected_files, tool_name)
  
  all_data <- list(idle_data, clustershift_data, selected_data) %>% 
    compact() %>% 
    bind_rows()
  
  return(all_data)
}

# ============================================================
# 6. Plot-Funktion
# ============================================================

all_files_exist <- function(files) {
  all(file.exists(files))
}

blank_plot <- function() {
  ggplot() + theme_void()
}

create_subplot <- function(db, db_type, conn_tool, cluster_type) {
  data <- collect_data_for_combination(db, db_type, conn_tool, cluster_type)
  
  title <- paste0(toupper(substring(cluster_type, 1, 1)), substring(cluster_type, 2))
  
  tool_name <- conn_labels[match(conn_tool, connectivity_tools)]
  dynamic_colors <- c("Idle" = "#2E86AB", 
                      "Clustershift" = "#A23B72")
  dynamic_colors[tool_name] <- "#F18F01"
  
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
  
  configs <- list(
    # PostgreSQL Operator
    list(db="postgres", db_type="operator", cluster_type="origin"),
    list(db="postgres", db_type="operator", cluster_type="target"),
    # PostgreSQL Stateful
    list(db="postgres", db_type="stateful", cluster_type="origin"),
    list(db="postgres", db_type="stateful", cluster_type="target"),
    # MongoDB Operator
    list(db="mongo", db_type="operator", cluster_type="origin"),
    list(db="mongo", db_type="operator", cluster_type="target"),
    # MongoDB Stateful
    list(db="mongo", db_type="stateful", cluster_type="origin"),
    list(db="mongo", db_type="stateful", cluster_type="target")
  )
  
  plots <- list()
  
  for(cfg in configs) {
    # Prüfe, ob alle Dateien existieren
    idle_files <- get_idle_files(cfg$cluster_type, cfg$db, cfg$db_type)
    clustershift_files <- get_migration_files(cfg$db, cfg$db_type, conn_tool, "clustershift", cfg$cluster_type)
    selected_files <- get_migration_files(cfg$db, cfg$db_type, conn_tool, "selected_tool", cfg$cluster_type)
    
    if (all(file.exists(idle_files)) && all(file.exists(clustershift_files)) && all(file.exists(selected_files))) {
      plots[[length(plots) + 1]] <- create_subplot(cfg$db, cfg$db_type, conn_tool, cfg$cluster_type)
    } else {
      plots[[length(plots) + 1]] <- blank_plot()
    }
  }
  
  # Grid: 2 Zeilen × 4 Spalten
  grid <- wrap_plots(plots, nrow = 2, ncol = 4)
  return(grid)
}

# ============================================================
# 7. Legende-Funktion
# ============================================================

create_legend_plot <- function(conn_tool) {
  tool_name <- conn_labels[match(conn_tool, connectivity_tools)]
  
  dummy_data <- data.frame(
    time_index = rep(1:3, 3),
    cluster_memory_usage_mb = rep(c(10, 20, 30), 3),
    migration_type = rep(c("Idle", "Clustershift", tool_name), each = 3)
  )
  
  dummy_data$migration_type <- factor(dummy_data$migration_type, 
                                      levels = c("Idle", "Clustershift", tool_name))
  
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
          legend.text = element_text(size = 16, margin = margin(l = 15, r = 15)),
          legend.title = element_text(size = 16, face = "bold"),
          legend.margin = margin(t = 10),
          legend.key.width = unit(2, "cm"),
          legend.key.height = unit(0.5, "cm")) +
    guides(color = guide_legend(override.aes = list(linewidth = 2, alpha = 1)))
  
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
# 8. Finale Plot-Funktion
# ============================================================

create_final_plot <- function(conn_tool) {
  main_grid <- create_connectivity_tool_grid(conn_tool)
  legend <- create_legend_plot(conn_tool)
  column_headers <- create_column_headers()
  row_labels <- create_row_labels()
  
  with_row_labels <- plot_grid(
    row_labels, main_grid,
    ncol = 2,
    rel_widths = c(0.08, 0.92)
  )
  
  with_headers <- plot_grid(
    column_headers, with_row_labels,
    ncol = 1,
    rel_heights = c(0.06, 0.94)
  )
  
  final_plot <- plot_grid(
    with_headers, legend,
    ncol = 1,
    rel_heights = c(0.9, 0.1)
  )
  
  return(final_plot)
}

# ============================================================
# 9. MAIN: Plots erstellen und als PDF speichern
# ============================================================

cat("=== ERSTELLE UND SPEICHERE PLOTS FÜR ALLE CONNECTIVITY TOOLS ===\n")
cat("Output-Pfad:", output_path, "\n")
cat("PDF-Einstellungen:", PDF_WIDTH, "x", PDF_HEIGHT, "Zoll bei", PDF_DPI, "DPI\n")
cat("Verwende feste Achsenlimits: X = 0-", FIXED_TIME_MAX, "s, Y = 0-", FIXED_MEMORY_MAX, "%\n\n")

for(conn_tool in connectivity_tools) {
  tool_name <- conn_labels[match(conn_tool, connectivity_tools)]
  cat("--- Erstelle Plot für", conn_tool, "(", tool_name, ") ---\n")
  
  final_plot <- create_final_plot(conn_tool)
  
  pdf_filename <- paste0("memory_usage_analysis_", conn_tool, ".pdf")
  pdf_filepath <- file.path(output_path, pdf_filename)
  
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