# Load necessary libraries using pacman for efficient package management
if (!require("pacman")) install.packages("pacman")
pacman::p_load(ggplot2, dplyr, data.table)

# Function to read and preprocess data
load_and_preprocess <- function(file_path, scenario_name) {
  # Use fread from data.table for faster reading - adjusting column names
  dt <- data.table::fread(
    file_path,
    select = c("message/method", "message/timestamp", "response_time_ms")
  )
  
  # Rename columns to make them more R-friendly
  setnames(dt, 
           old = c("message/method", "message/timestamp"),
           new = c("method", "timestamp"))
  
  # Convert to data.table and process timestamp more efficiently
  dt[, `:=`(
    timestamp = as.POSIXct(timestamp, format = "%Y-%m-%dT%H:%M:%OS"),
    dataset = scenario_name
  )]
  
  return(dt)
}

# Function to calculate time metrics
calculate_time_metrics <- function(dt) {
  # Calculate reference time once
  ref_time <- min(dt$timestamp)
  
  dt[, `:=`(
    elapsed_minutes = as.numeric(difftime(timestamp, ref_time, units = "mins")),
    timestamp = NULL
  )]
  
  return(dt[elapsed_minutes >= 1 & elapsed_minutes <= 6])
}


create_boxplot <- function(dt) {
  # Filter data for GET and POST methods
  dt_get_post <- dt[method %in% c("GET", "POST")]
  
  # Common theme settings
  my_theme <- theme_minimal() +
    theme(
      # Larger axis text
      axis.text.x = element_text(
        size = 22,                                               # Increased from 20
        face = "bold",
        margin = margin(t = 15)                                  # Add space above x-axis text
      ),
      axis.text.y = element_text(
        size = 20,                                               # Increased from 18
        margin = margin(r = 15)                                  # Add space right of y-axis text
      ),
      # Larger axis titles with more spacing
      axis.title.y = element_text(
        size = 22,                                               # Increased from 20
        face = "bold",
        margin = margin(r = 30, l = 0)                          # Increased spacing from axis
      ),
      legend.position = "none",
      panel.grid.minor = element_blank(),
      plot.title = element_text(
        hjust = 0.5, 
        face = "bold", 
        size = 24,                                              # Increased from 24
        margin = margin(b = 30)                                 # Increased spacing below title
      )
    )
  
  # Create separate plots for GET and POST
  plot_get <- ggplot(dt_get_post[method == "GET"], 
                     aes(x = dataset, y = response_time_ms, fill = dataset)) +
    geom_boxplot(outlier.size = 3, outlier.colour = "red", width = 0.5) +    # Increased outlier size
    scale_fill_manual(values = c("Idle" = "#4db8b8", "Migration" = "#ffa500")) +
    labs(
      x = "",
      y = "Response Time (ms)",
      title = "GET Requests"
    ) +
    my_theme
  
  plot_post <- ggplot(dt_get_post[method == "POST"], 
                      aes(x = dataset, y = response_time_ms, fill = dataset)) +
    geom_boxplot(outlier.size = 3, outlier.colour = "red", width = 0.5) +    # Increased outlier size
    scale_fill_manual(values = c("Idle" = "#4db8b8", "Migration" = "#ffa500")) +
    labs(
      x = "",
      y = "",
      title = "POST Requests"
    ) +
    my_theme
  
  # Combine plots side by side using patchwork
  library(patchwork)
  combined_plot <- plot_get + plot_post +
    plot_layout(ncol = 2, widths = c(1, 1)) +
    plot_annotation(
      theme = theme(
        legend.position = "top",
        plot.margin = margin(30, 30, 30, 30)  # Increased overall plot margins
      )
    )
  
  return(combined_plot)
}

calculate_stats <- function(dt) {
  dt[, .(
    avg_response_time = mean(response_time_ms, na.rm = TRUE),
    std_dev_response_time = sd(response_time_ms, na.rm = TRUE),
    ci_lower = mean(response_time_ms, na.rm = TRUE) - 
      qt(0.975, .N - 1) * sd(response_time_ms, na.rm = TRUE) / sqrt(.N),
    ci_upper = mean(response_time_ms, na.rm = TRUE) + 
      qt(0.975, .N - 1) * sd(response_time_ms, na.rm = TRUE) / sqrt(.N),
    n = .N
  ), by = .(method, dataset)]
}

# Main processing pipeline (updated for boxplot with separate scales)
main_boxplot <- function() {
  # Define file paths
  base_path <- "/Users/romankudravcev/Desktop/masterarbeit/benchmark_results/response_time"
  files <- list(
    Idle = file.path(base_path, "response-time-idle.csv"),
    Migration = file.path(base_path, "response-time-migration.csv")
  )
  
  # Load and process data
  dt_list <- lapply(names(files), function(scenario) {
    dt <- load_and_preprocess(files[[scenario]], scenario)
    calculate_time_metrics(dt)
  })
  
  # Combine datasets
  combined_dt <- rbindlist(dt_list)
  
  # Create the boxplot for GET and POST methods with separate y-axis scales
  boxplot <- create_boxplot(combined_dt)
  
  # Calculate statistics
  stats <- calculate_stats(combined_dt)
  
  # Return results
  list(
    plot = boxplot,
    statistics = stats,
    data = combined_dt
  )
}

# Run analysis for boxplot with separate scales
results_boxplot <- main_boxplot()

# Display boxplot and statistics
print(results_boxplot$plot)
print(results_boxplot$statistics)

# Create a timestamp for the filename
timestamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
username <- "romankudravcev"
filename <- sprintf("response_time_%s_%s.pdf", username, timestamp)

# Save the plot as PDF
# Width and height are in inches
ggsave(
  filename = filename,
  plot = results_boxplot$plot,
  device = "pdf",
  width = 15,
  height = 8,
  dpi = 300
)
