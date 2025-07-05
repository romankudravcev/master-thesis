# Load necessary libraries
library(ggplot2)
library(gridExtra)
library(patchwork)

# Read the three CSV files
data_idle_origin <- read.csv("/Users/romankudravcev/Desktop/masterarbeit/benchmark_results/util/metrics-idle-origin.csv")
data_idle_target <- read.csv("/Users/romankudravcev/Desktop/masterarbeit/benchmark_results/util/metrics-idle-target.csv")
data_migration_origin <- read.csv("/Users/romankudravcev/Desktop/masterarbeit/benchmark_results/util/metrics-migration-origin.csv")
data_migration_target <- read.csv("/Users/romankudravcev/Desktop/masterarbeit/benchmark_results/util/metrics-migration-target.csv")

# Convert timestamp to POSIXct format
data_idle_origin$timestamp <- as.POSIXct(substr(data_idle_origin$timestamp, 1, 19), format = "%Y-%m-%dT%H:%M:%S", tz = "UTC")
data_idle_target$timestamp <- as.POSIXct(substr(data_idle_target$timestamp, 1, 19), format = "%Y-%m-%dT%H:%M:%S", tz = "UTC")
data_migration_origin$timestamp <- as.POSIXct(substr(data_migration_origin$timestamp, 1, 19), format = "%Y-%m-%dT%H:%M:%S", tz = "UTC")
data_migration_target$timestamp <- as.POSIXct(substr(data_migration_target$timestamp, 1, 19), format = "%Y-%m-%dT%H:%M:%S", tz = "UTC")

# Remove the first minute (60 seconds) from each dataset
data_idle_origin <- data_idle_origin[data_idle_origin$timestamp > min(data_idle_origin$timestamp) + 60, ]
data_idle_target <- data_idle_target[data_idle_target$timestamp > min(data_idle_target$timestamp) + 60, ]
data_migration_origin <- data_migration_origin[data_migration_origin$timestamp > min(data_migration_origin$timestamp) + 60, ]
data_migration_target <- data_migration_target[data_migration_target$timestamp > min(data_migration_target$timestamp) + 60, ]

# Subset to take only the next 5 minutes (300 seconds)
max_time_idle_origin <- min(data_idle_origin$timestamp) + 300
max_time_idle_target <- min(data_idle_target$timestamp) + 300
max_time_migration_origin <- min(data_migration_origin$timestamp) + 300
max_time_migration_target <- min(data_migration_target$timestamp) + 300

data_idle_origin <- data_idle_origin[data_idle_origin$timestamp <= max_time_idle_origin, ]
data_idle_target <- data_idle_target[data_idle_target$timestamp <= max_time_idle_target, ]
data_migration_origin <- data_migration_origin[data_migration_origin$timestamp <= max_time_migration_origin, ]
data_migration_target <- data_migration_target[data_migration_target$timestamp <= max_time_migration_target, ]

# Convert memory usage to MB for all data sets
data_idle_origin$memory_usage_mb <- data_idle_origin$memory_usage / (1024^2)
data_idle_target$memory_usage_mb <- data_idle_target$memory_usage / (1024^2)
data_migration_origin$memory_usage_mb <- data_migration_origin$memory_usage / (1024^2)
data_migration_target$memory_usage_mb <- data_migration_target$memory_usage / (1024^2)

# Aggregate data by time index (relative to when the script starts) for CPU and memory usage
data_idle_origin$time_index <- as.numeric(difftime(data_idle_origin$timestamp, min(data_idle_origin$timestamp), units = "secs"))
data_idle_target$time_index <- as.numeric(difftime(data_idle_target$timestamp, min(data_idle_target$timestamp), units = "secs"))
data_migration_origin$time_index <- as.numeric(difftime(data_migration_origin$timestamp, min(data_migration_origin$timestamp), units = "secs"))
data_migration_target$time_index <- as.numeric(difftime(data_migration_target$timestamp, min(data_migration_target$timestamp), units = "secs"))

# Aggregate data by time index for CPU and memory usage
agg_idle_origin <- aggregate(cbind(memory_usage_mb, cluster_cpu_usage) ~ time_index, data = data_idle_origin, sum)
data_idle_target <- aggregate(cbind(memory_usage_mb, cluster_cpu_usage) ~ time_index, data = data_idle_target, sum)
agg_migration_origin <- aggregate(cbind(memory_usage_mb, cluster_cpu_usage) ~ time_index, data = data_migration_origin, sum)
agg_migration_target <- aggregate(cbind(memory_usage_mb, cluster_cpu_usage) ~ time_index, data = data_migration_target, sum)

# Create a combined dataset for CPU comparison (Idle Origin vs Migration Origin)
agg_idle_origin$dataset <- "Idle Origin"
agg_migration_origin$dataset <- "Migration Origin"
agg_all_cpu_idle_vs_migration_origin <- rbind(agg_idle_origin[, c("time_index", "cluster_cpu_usage", "dataset")],
                                              agg_migration_origin[, c("time_index", "cluster_cpu_usage", "dataset")])

# Create a combined dataset for Memory comparison (Idle Origin vs Migration Origin)
agg_all_memory_idle_vs_migration_origin <- rbind(agg_idle_origin[, c("time_index", "memory_usage_mb", "dataset")],
                                                 agg_migration_origin[, c("time_index", "memory_usage_mb", "dataset")])

# Reset dataset name for target comparison
data_idle_target$dataset <- "Idle Target"  # This is actually for target comparison
agg_migration_target$dataset <- "Migration Target"
agg_all_cpu_idle_vs_migration_target <- rbind(data_idle_target[, c("time_index", "cluster_cpu_usage", "dataset")],
                                              agg_migration_target[, c("time_index", "cluster_cpu_usage", "dataset")])

# Create a combined dataset for Memory comparison (Idle Target vs Migration Target)
agg_all_memory_idle_vs_migration_target <- rbind(data_idle_target[, c("time_index", "memory_usage_mb", "dataset")],
                                                 agg_migration_target[, c("time_index", "memory_usage_mb", "dataset")])

# Define a professional color palette
idle_origin_color <- "#2E86C1"    # Steel Blue
migration_origin_color <- "#27AE60"  # Emerald Green
idle_target_color <- "#8E44AD"     # Royal Purple
migration_target_color <- "#E74C3C"  # Coral Red

# Define common theme settings
my_theme <- theme_minimal() +
  theme(
    # Increase text sizes
    axis.text = element_text(size = 16),          # Axis numbers
    axis.title = element_text(size = 16),         # Axis titles
    legend.text = element_text(size = 16),        # Legend text
    legend.title = element_text(size = 16),       # Legend title
    
    # Add margin between axis title and axis
    axis.title.x = element_text(margin = margin(t = 20, b = 0)),    # Add space above x-axis title
    axis.title.y = element_text(margin = margin(r = 20, l = 0)),    # Add space right of y-axis title
    
    # Legend positioning and size
    legend.position = "bottom",
    legend.key.size = unit(1.2, "cm")            # Slightly larger legend keys
  )

# Create CPU comparison plot for Idle Origin vs Migration Origin
cpu_comparison_origin <- ggplot() +
  geom_line(data = agg_all_cpu_idle_vs_migration_origin, aes(x = time_index, y = cluster_cpu_usage, color = dataset), size = 1) +
  labs(x = "Time (seconds)", y = "CPU Usage in %") +
  scale_y_continuous(limits = c(0, 80), breaks = seq(0, 75, 10)) +  # Adjusted to 80%
  scale_color_manual(values = c(idle_origin_color, migration_origin_color)) +
  my_theme

# Create Memory comparison plot for Idle Origin vs Migration Origin
memory_comparison_origin <- ggplot() +
  geom_line(data = agg_all_memory_idle_vs_migration_origin, aes(x = time_index, y = memory_usage_mb, color = dataset), size = 1) +
  labs(x = "Time (seconds)", y = "Memory Usage (MB)") +
  scale_y_continuous(limits = c(0, 3000), breaks = seq(0, 2750, 500)) +  # Adjusted to 3000MB
  scale_color_manual(values = c(idle_origin_color, migration_origin_color)) +
  my_theme

# Create CPU comparison plot for Idle Target vs Migration Target
cpu_comparison_target <- ggplot() +
  geom_line(data = agg_all_cpu_idle_vs_migration_target, aes(x = time_index, y = cluster_cpu_usage, color = dataset), size = 1) +
  labs(x = "Time (seconds)", y = NULL) +
  scale_y_continuous(limits = c(0, 80), breaks = seq(0, 75, 10)) +  # Adjusted to 80%
  scale_color_manual(values = c(idle_target_color, migration_target_color)) +
  my_theme

# Create Memory comparison plot for Idle Target vs Migration Target
memory_comparison_target <- ggplot() +
  geom_line(data = agg_all_memory_idle_vs_migration_target, aes(x = time_index, y = memory_usage_mb, color = dataset), size = 1) +
  labs(x = "Time (seconds)", y = NULL) +
  scale_y_continuous(limits = c(0, 3000), breaks = seq(0, 2750, 500)) +  # Adjusted to 3000MB
  scale_color_manual(values = c(idle_target_color, migration_target_color)) +
  my_theme

# Create a unified legend title
legend_title <- ""

# Update each plot with the same legend title
cpu_comparison_origin <- cpu_comparison_origin + ggtitle("Origin Cluster") + theme(plot.title = element_text(size = 16, face = "bold", hjust = 0.5))
memory_comparison_origin <- memory_comparison_origin + ggtitle("Origin Cluster") + theme(plot.title = element_text(size = 16, face = "bold", hjust = 0.5))
cpu_comparison_target <- cpu_comparison_target + ggtitle("Target Cluster") + theme(plot.title = element_text(size = 16, face = "bold", hjust = 0.5))
memory_comparison_target <- memory_comparison_target + ggtitle("Target Cluster") +theme(plot.title = element_text(size = 16, face = "bold", hjust = 0.5))

# Combine all the plots with patchwork
final_plot <- (cpu_comparison_origin | cpu_comparison_target | memory_comparison_origin | memory_comparison_target) +
  plot_layout(
    nrow = 1,
    guides = "collect"
  ) +
  plot_annotation(
    theme = theme(
      plot.title = element_text(size = 20, face = "bold", hjust = 0.5),
      plot.subtitle = element_text(size = 14, hjust = 0.5),
    )
  ) & 
  theme(
    legend.position = "bottom",
    legend.text = element_text(size = 16),
    legend.title = element_text(size = 0),
    legend.key.size = unit(1.2, "cm")
  )


# Display the final plot
final_plot

# Create a timestamp for the filename
timestamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
username <- "romankudravcev"
filename <- sprintf("system_metrics_comparison_%s_%s.pdf", username, timestamp)

# Save the plot as PDF
# Width and height are in inches
ggsave(
  filename = filename,
  plot = final_plot,
  device = "pdf",
  width = 15,
  height = 5,
  dpi = 300
)

# Print confirmation message
cat(sprintf("Plot saved as '%s'\n", filename))
