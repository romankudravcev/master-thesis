# ============================================================
# Benchmark Analysis Script with Idle Scenarios Integration
#         and Separated GET/POST Response Times
# ============================================================

library(jsonlite)
library(dplyr)
library(knitr)
library(xtable)
library(lubridate)

# ============================================================
# Configuration
# ============================================================

base_path <- "/Users/romankudravcev/Desktop/master-thesis/benchmark-analysis/results"
output_path <- "/Users/romankudravcev/Desktop/master-thesis/benchmark-analysis/analysis"

databases <- c("postgres", "mongo")
db_types <- c("operator", "stateful")
connectivity_tools <- c("submariner", "linkerd", "skupper")
reroute_tools <- c("clustershift", "selected_tool")

db_labels <- c("PostgreSQL" = "postgres", "MongoDB" = "mongo")
type_labels <- c("Operator" = "operator", "StatefulSet" = "stateful")
conn_labels <- c("Submariner" = "submariner", "Linkerd" = "linkerd", "Skupper" = "skupper")

# ============================================================
# File fetching functions
# ============================================================

get_benchmark_files <- function(db, db_type, conn_tool, reroute_tool) {
  actual_reroute <- ifelse(reroute_tool == "selected_tool", conn_tool, reroute_tool)
  db_full <- paste0(db, "_", db_type)
  file_paths <- file.path(base_path, 
                          conn_tool, 
                          paste0(db_full, "_", actual_reroute),
                          paste0(conn_tool, "_", db_full, "_", actual_reroute, "_", 1:3, ".json"))
  return(file_paths)
}

get_log_files <- function(db, db_type, conn_tool, reroute_tool) {
  actual_reroute <- ifelse(reroute_tool == "selected_tool", conn_tool, reroute_tool)
  db_full <- paste0(db, "_", db_type)
  log_paths <- file.path(base_path, 
                         conn_tool, 
                         paste0(db_full, "_", actual_reroute),
                         paste0(conn_tool, "_", db_full, "_", actual_reroute, "_", 1:3, ".log"))
  return(log_paths)
}

get_idle_benchmark_files <- function(db, db_type) {
  idle_path <- file.path(base_path, "idle_origin", paste0(db, "_", db_type))
  file_paths <- file.path(idle_path, paste0("idle_", db, "_", db_type, "_", 1:3, ".json"))
  return(file_paths)
}

# ============================================================
# Function to read JSON with preserved structure using different approach
# ============================================================

read_json_preserve_structure <- function(file_path) {
  tryCatch({
    json_text <- readLines(file_path, warn = FALSE)
    json_text <- paste(json_text, collapse = "\n")
    data <- fromJSON(json_text, simplifyVector = FALSE, simplifyDataFrame = FALSE)
    return(data)
  }, error = function(e) {
    cat("Error reading JSON with preserved structure:", e$message, "\n")
    return(fromJSON(file_path))
  })
}

# ============================================================
# Function to calculate downtime from POST request failures
# ============================================================

calculate_downtime_from_json <- function(json_data) {
  tryCatch({
    results <- NULL
    if ("results" %in% names(json_data)) {
      results <- json_data$results
    }
    if (is.null(results) || length(results) == 0) {
      cat("    No results data found\n")
      return(0)
    }
    cat("    Found", length(results), "total requests\n")
    post_data <- data.frame(
      timestamp = character(0),
      success = logical(0),
      stringsAsFactors = FALSE
    )
    if (is.list(results) && !is.data.frame(results)) {
      for (i in 1:length(results)) {
        result <- results[[i]]
        if (is.list(result)) {
          method <- NULL
          if ("message" %in% names(result) && is.list(result$message)) {
            method <- result$message$method
          }
          timestamp <- NULL
          if ("message" %in% names(result) && is.list(result$message)) {
            timestamp <- result$message$timestamp
          }
          success <- result$success
          if (!is.null(method) && !is.null(timestamp) && !is.null(success)) {
            if (method == "POST" && is.logical(success) && length(success) == 1) {
              post_data <- rbind(post_data, data.frame(
                timestamp = as.character(timestamp),
                success = success,
                stringsAsFactors = FALSE
              ))
            }
          }
        }
      }
    } else if (is.data.frame(results)) {
      cat("    Results structure is flattened - using summary data for downtime estimation\n")
      post_results <- results[results$method == "POST", ]
      if (nrow(post_results) > 0) {
        cat("    Found", nrow(post_results), "POST requests in flattened structure\n")
        if ("failed_posts" %in% names(json_data)) {
          failed_posts <- as.numeric(json_data$failed_posts)
          total_posts <- nrow(post_results)
          if (failed_posts > 0) {
            timestamps <- as.POSIXct(post_results$timestamp, format = "%Y-%m-%dT%H:%M:%OSZ")
            timestamps <- timestamps[!is.na(timestamps)]
            if (length(timestamps) > 1) {
              total_duration <- as.numeric(difftime(max(timestamps), min(timestamps), units = "secs"))
              failure_rate <- failed_posts / total_posts
              estimated_downtime <- total_duration * failure_rate
              cat("    Estimated downtime based on failure rate:", round(estimated_downtime, 2), "seconds\n")
              cat("    (", failed_posts, "failed out of", total_posts, "total POST requests)\n")
              return(estimated_downtime)
            }
          }
        }
      }
      return(0)
    }
    if (nrow(post_data) == 0) {
      cat("    No POST requests found\n")
      return(0)
    }
    cat("    Found", nrow(post_data), "POST requests\n")
    post_data$ts <- as.POSIXct(post_data$timestamp, format = "%Y-%m-%dT%H:%M:%OSZ")
    post_data <- post_data[!is.na(post_data$ts), ]
    if (nrow(post_data) == 0) {
      cat("    No valid timestamps found\n")
      return(0)
    }
    post_data <- post_data[order(post_data$ts), ]
    post_data$is_failure <- !post_data$success
    failed_count <- sum(post_data$is_failure)
    cat("    Found", failed_count, "failed POST requests out of", nrow(post_data), "\n")
    if (failed_count == 0) {
      cat("    No failed POST requests - downtime is 0\n")
      return(0)
    }
    rle_failures <- rle(post_data$is_failure)
    failure_starts <- c(1, cumsum(rle_failures$lengths[-length(rle_failures$lengths)]) + 1)
    failure_ends <- cumsum(rle_failures$lengths)
    failure_indices <- which(rle_failures$values == TRUE)
    if (length(failure_indices) == 0) {
      cat("    No consecutive failure periods found\n")
      return(0)
    }
    total_downtime <- 0
    for (i in failure_indices) {
      start_idx <- failure_starts[i]
      end_idx <- failure_ends[i]
      start_time <- post_data$ts[start_idx]
      end_time <- post_data$ts[end_idx]
      duration <- as.numeric(difftime(end_time, start_time, units = "secs"))
      total_downtime <- total_downtime + duration
      cat("    Failure period", which(failure_indices == i), ":", 
          round(duration, 2), "seconds (",
          (end_idx - start_idx + 1), "failed requests from",
          format(start_time, "%H:%M:%S"), "to", format(end_time, "%H:%M:%S"), ")\n")
    }
    cat("    Total downtime:", round(total_downtime, 2), "seconds\n")
    return(total_downtime)
  }, error = function(e) {
    cat("    Error calculating downtime:", e$message, "\n")
    return(0)
  })
}

# ============================================================
# Function to parse migration time from log file
# ============================================================

parse_migration_time <- function(log_file_path) {
  if (!file.exists(log_file_path)) {
    cat("  Log file not found:", log_file_path, "\n")
    return(NA)
  }
  tryCatch({
    log_lines <- readLines(log_file_path)
    start_pattern <- "\\[INFO\\] Initializing kubernetes clients"
    end_pattern <- "\\[INFO\\] Migration complete"
    start_line <- grep(start_pattern, log_lines, value = TRUE)[1]
    end_line <- grep(end_pattern, log_lines, value = TRUE)[1]
    if (is.na(start_line) || is.na(end_line)) {
      cat("  Could not find start or end markers in log file\n")
      return(NA)
    }
    start_timestamp <- gsub("^(\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}).*", "\\1", start_line)
    end_timestamp <- gsub("^(\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}).*", "\\1", end_line)
    start_time <- ymd_hms(start_timestamp)
    end_time <- ymd_hms(end_timestamp)
    migration_time <- as.numeric(difftime(end_time, start_time, units = "secs"))
    cat("  Migration time:", round(migration_time, 2), "seconds\n")
    return(migration_time)
  }, error = function(e) {
    cat("  Error parsing log file:", e$message, "\n")
    return(NA)
  })
}

# ============================================================
# Function to process a single benchmark JSON file
# ============================================================

process_benchmark_file <- function(file_path) {
  if (!file.exists(file_path)) {
    return(NULL)
  }
  tryCatch({
    data <- read_json_preserve_structure(file_path)
    successful_posts <- as.numeric(data$successful_posts %||% 0)
    failed_posts <- as.numeric(data$failed_posts %||% 0)
    successful_gets <- as.numeric(data$successful_gets %||% 0)
    failed_gets <- as.numeric(data$failed_gets %||% 0)
    total_requests_calc <- successful_posts + failed_posts + successful_gets + failed_gets
    successful_requests <- successful_posts + successful_gets
    availability <- (successful_requests / total_requests_calc) * 100
    server_posts_text <- as.character(data$`Server successful POST requests` %||% "0 (Client: 0)")
    if (grepl("\\d+\\s*\\(Client:\\s*\\d+\\)", server_posts_text)) {
      server_posts_raw <- as.numeric(gsub("^(\\d+).*", "\\1", server_posts_text))
      client_posts <- as.numeric(gsub(".*Client:\\s*(\\d+).*", "\\1", server_posts_text))
    } else if (grepl("\\d+\\s*\\(\\d+\\)", server_posts_text)) {
      server_posts_raw <- as.numeric(gsub("^(\\d+).*", "\\1", server_posts_text))
      client_posts <- as.numeric(gsub(".*\\((\\d+)\\).*", "\\1", server_posts_text))
    } else {
      server_posts_raw <- successful_posts + 1000
      client_posts <- successful_posts
    }
    server_posts_corrected <- server_posts_raw - 1000
    if (is.na(server_posts_corrected) || is.na(client_posts)) {
      message_lost_rate <- 0
      messages_lost <- 0
    } else {
      messages_lost <- server_posts_corrected - client_posts
      message_lost_rate <- (messages_lost / total_requests_calc) * 100
    }
    
    avg_response_time_get <- NA
    avg_response_time_post <- NA
    
    if ("results" %in% names(data)) {
      results <- data$results
      if (is.list(results) && !is.data.frame(results)) {
        get_times <- c()
        post_times <- c()
        for (result in results) {
          if (is.list(result)) {
            method <- NULL
            response_time <- NULL
            if ("message" %in% names(result) && is.list(result$message)) {
              method <- result$message$method
            }
            if ("response_time_ms" %in% names(result)) {
              response_time <- as.numeric(result$response_time_ms)
            }
            if (!is.null(method) && !is.null(response_time) && !is.na(response_time)) {
              if (method == "GET") {
                get_times <- c(get_times, response_time)
              } else if (method == "POST") {
                post_times <- c(post_times, response_time)
              }
            }
          }
        }
        if (length(get_times) > 0) avg_response_time_get <- mean(get_times)
        if (length(post_times) > 0) avg_response_time_post <- mean(post_times)
      } else if (is.data.frame(results)) {
        if ("method" %in% names(results) && "response_time_ms" %in% names(results)) {
          get_times <- as.numeric(results$response_time_ms[results$method == "GET"])
          post_times <- as.numeric(results$response_time_ms[results$method == "POST"])
          if (length(get_times) > 0) avg_response_time_get <- mean(get_times, na.rm = TRUE)
          if (length(post_times) > 0) avg_response_time_post <- mean(post_times, na.rm = TRUE)
        }
      }
    }
    # Fallback: if not available, use the overall average
    if (is.na(avg_response_time_get) || is.na(avg_response_time_post)) {
      if ("total_response_time_ms" %in% names(data)) {
        total_response_time <- as.numeric(data$total_response_time_ms)
        if (!is.na(total_response_time) && total_requests_calc > 0) {
          overall_avg_response_time <- total_response_time / total_requests_calc
          if (is.na(avg_response_time_get)) avg_response_time_get <- overall_avg_response_time
          if (is.na(avg_response_time_post)) avg_response_time_post <- overall_avg_response_time
        }
      }
    }

    cat("  Calculating downtime from JSON data:\n")
    downtime_seconds <- calculate_downtime_from_json(data)
    return(data.frame(
      Successful_GET = successful_gets,
      Successful_POST = successful_posts,
      Failed_GET = failed_gets,
      Failed_POST = failed_posts,
      Availability = availability,
      Message_Lost_Rate = message_lost_rate,
      Response_Time_GET = avg_response_time_get,
      Response_Time_POST = avg_response_time_post,
      Downtime_Seconds = downtime_seconds,
      stringsAsFactors = FALSE
    ))
  }, error = function(e) {
    cat("✗ Error processing file", basename(file_path), ":", e$message, "\n")
    return(NULL)
  })
}

`%||%` <- function(x, y) if(is.null(x)) y else x

# ============================================================
# Function to create a missing scenario row with "--" values
# ============================================================

create_missing_scenario <- function(db, db_type, conn_tool, reroute_tool) {
  forwarding_tool <- ifelse(reroute_tool == "selected_tool", 
                            names(conn_labels)[conn_labels == conn_tool], "Clustershift")
  return(data.frame(
    Connectivity_Tool = conn_tool,
    Database = db,
    Deployment = db_type,
    Forwarding_Tool = forwarding_tool,
    Successful_GET_mean = NA,
    Successful_GET_sd = NA,
    Successful_POST_mean = NA,
    Successful_POST_sd = NA,
    Failed_GET_mean = NA,
    Failed_GET_sd = NA,
    Failed_POST_mean = NA,
    Failed_POST_sd = NA,
    Availability_mean = NA,
    Availability_sd = NA,
    Message_Lost_Rate_mean = NA,
    Message_Lost_Rate_sd = NA,
    Response_Time_GET_mean = NA,
    Response_Time_GET_sd = NA,
    Response_Time_POST_mean = NA,
    Response_Time_POST_sd = NA,
    Migration_Time_mean = NA,
    Migration_Time_sd = NA,
    Downtime_mean = NA,
    Downtime_sd = NA,
    stringsAsFactors = FALSE
  ))
}

# ============================================================
# Function to process exactly 3 runs and calculate mean + std dev
# ============================================================

process_scenario <- function(db, db_type, conn_tool, reroute_tool) {
  if (conn_tool == "skupper" && db == "postgres" && db_type == "stateful") {
    cat("Processing:", conn_tool, db, db_type, "→ MISSING DATA (adding -- values)\n")
    return(create_missing_scenario(db, db_type, conn_tool, reroute_tool))
  }
  file_paths <- get_benchmark_files(db, db_type, conn_tool, reroute_tool)
  log_paths <- get_log_files(db, db_type, conn_tool, reroute_tool)
  forwarding_tool <- ifelse(reroute_tool == "selected_tool", 
                            names(conn_labels)[conn_labels == conn_tool], "Clustershift")
  cat("Processing:", conn_tool, db, db_type, forwarding_tool, "\n")
  run_results <- list()
  migration_times <- c()
  for (i in 1:3) {
    cat("  Processing run", i, ":", basename(file_paths[i]), "\n")
    result <- process_benchmark_file(file_paths[i])
    if (!is.null(result)) {
      run_results[[i]] <- result
    } else {
      cat("  Missing run", i, "for", conn_tool, db, db_type, forwarding_tool, "\n")
    }
    cat("  Processing log file", i, ":", basename(log_paths[i]), "\n")
    migration_time <- parse_migration_time(log_paths[i])
    migration_times[i] <- migration_time
  }
  if (length(run_results) == 3) {
    combined_df <- bind_rows(run_results)
    summary_result <- combined_df %>%
      summarise(
        Connectivity_Tool = conn_tool,
        Database = db,
        Deployment = db_type,
        Forwarding_Tool = forwarding_tool,
        Successful_GET_mean = round(mean(Successful_GET), 1),
        Successful_GET_sd = round(sd(Successful_GET), 2),
        Successful_POST_mean = round(mean(Successful_POST), 1),
        Successful_POST_sd = round(sd(Successful_POST), 2),
        Failed_GET_mean = round(mean(Failed_GET), 1),
        Failed_GET_sd = round(sd(Failed_GET), 2),
        Failed_POST_mean = round(mean(Failed_POST), 1),
        Failed_POST_sd = round(sd(Failed_POST), 2),
        Availability_mean = round(mean(Availability), 2),
        Availability_sd = round(sd(Availability), 2),
        Message_Lost_Rate_mean = round(mean(Message_Lost_Rate), 2),
        Message_Lost_Rate_sd = round(sd(Message_Lost_Rate), 2),
        Response_Time_GET_mean = round(mean(Response_Time_GET, na.rm = TRUE), 2),
        Response_Time_GET_sd = round(sd(Response_Time_GET, na.rm = TRUE), 2),
        Response_Time_POST_mean = round(mean(Response_Time_POST, na.rm = TRUE), 2),
        Response_Time_POST_sd = round(sd(Response_Time_POST, na.rm = TRUE), 2),
        Migration_Time_mean = round(mean(migration_times, na.rm = TRUE), 2),
        Migration_Time_sd = round(sd(migration_times, na.rm = TRUE), 2),
        Downtime_mean = round(mean(Downtime_Seconds, na.rm = TRUE), 2),
        Downtime_sd = round(sd(Downtime_Seconds, na.rm = TRUE), 2),
        .groups = "drop"
      )
    cat("✓ Processed 3 runs successfully\n")
    cat("  Migration Time:", summary_result$Migration_Time_mean, "±", summary_result$Migration_Time_sd, "seconds\n")
    cat("  Downtime:", summary_result$Downtime_mean, "±", summary_result$Downtime_sd, "seconds\n")
    return(summary_result)
  } else {
    cat("✗ Need exactly 3 runs, found", length(run_results), "→ SKIPPING\n")
    return(NULL)
  }
}

# ============================================================
# Function to process idle scenario (3 runs, just like others)
# ============================================================

process_idle_scenario <- function(db, db_type) {
  file_paths <- get_idle_benchmark_files(db, db_type)
  run_results <- list()
  for (i in 1:3) {
    result <- process_benchmark_file(file_paths[i])
    if (!is.null(result)) {
      run_results[[i]] <- result
    }
  }
  if (length(run_results) == 3) {
    combined_df <- bind_rows(run_results)
    summary_result <- combined_df %>%
      summarise(
        Connectivity_Tool = "idle",
        Database = db,
        Deployment = db_type,
        Forwarding_Tool = "none",
        Successful_GET_mean = round(mean(Successful_GET), 1),
        Successful_GET_sd = round(sd(Successful_GET), 2),
        Successful_POST_mean = round(mean(Successful_POST), 1),
        Successful_POST_sd = round(sd(Successful_POST), 2),
        Failed_GET_mean = round(mean(Failed_GET), 1),
        Failed_GET_sd = round(sd(Failed_GET), 2),
        Failed_POST_mean = round(mean(Failed_POST), 1),
        Failed_POST_sd = round(sd(Failed_POST), 2),
        Availability_mean = round(mean(Availability), 2),
        Availability_sd = round(sd(Availability), 2),
        Message_Lost_Rate_mean = round(mean(Message_Lost_Rate), 2),
        Message_Lost_Rate_sd = round(sd(Message_Lost_Rate), 2),
        Response_Time_GET_mean = round(mean(Response_Time_GET, na.rm = TRUE), 2),
        Response_Time_GET_sd = round(sd(Response_Time_GET, na.rm = TRUE), 2),
        Response_Time_POST_mean = round(mean(Response_Time_POST, na.rm = TRUE), 2),
        Response_Time_POST_sd = round(sd(Response_Time_POST, na.rm = TRUE), 2),
        Migration_Time_mean = NA,
        Migration_Time_sd = NA,
        Downtime_mean = NA,
        Downtime_sd = NA,
        .groups = "drop"
      )
    return(summary_result)
  } else {
    return(data.frame(
      Connectivity_Tool = "idle",
      Database = db,
      Deployment = db_type,
      Forwarding_Tool = "none",
      Successful_GET_mean = NA,
      Successful_GET_sd = NA,
      Successful_POST_mean = NA,
      Successful_POST_sd = NA,
      Failed_GET_mean = NA,
      Failed_GET_sd = NA,
      Failed_POST_mean = NA,
      Failed_POST_sd = NA,
      Availability_mean = NA,
      Availability_sd = NA,
      Message_Lost_Rate_mean = NA,
      Message_Lost_Rate_sd = NA,
      Response_Time_GET_mean = NA,
      Response_Time_GET_sd = NA,
      Response_Time_POST_mean = NA,
      Response_Time_POST_sd = NA,
      Migration_Time_mean = NA,
      Migration_Time_sd = NA,
      Downtime_mean = NA,
      Downtime_sd = NA,
      stringsAsFactors = FALSE
    ))
  }
}

# ============================================================
# Function to process all benchmarks including idle
# ============================================================

process_all_benchmarks <- function() {
  cat("=== PROCESSING ALL BENCHMARK SCENARIOS WITH WORKING STRUCTURE ===\n")
  cat("Date:", format(Sys.time(), "%Y-%m-%d %H:%M:%S"), "\n")
  cat("Base path:", base_path, "\n")
  cat("WORKING: Handles both flattened and preserved JSON structures\n")
  cat("WORKING: Uses estimation for downtime when detailed data unavailable\n")
  cat("CORRECTED: Message loss calculation subtracts 1000 initial entries from server count\n")
  cat("CORRECTED: Migration time calculated from log files\n\n")
  all_results <- data.frame()
  for (conn_tool in connectivity_tools) {
    for (db in databases) {
      for (db_type in db_types) {
        for (reroute_tool in reroute_tools) {
          result <- process_scenario(db, db_type, conn_tool, reroute_tool)
          if (!is.null(result)) {
            all_results <- rbind(all_results, result)
          }
        }
      }
    }
  }
  # Add idle scenarios
  for (db in databases) {
    for (db_type in db_types) {
      idle_result <- process_idle_scenario(db, db_type)
      all_results <- rbind(all_results, idle_result)
    }
  }
  return(all_results)
}

# ============================================================
# Function to create formatted values with mean ± std dev
# ============================================================

format_value_with_std <- function(mean_vals, sd_vals, unit = "") {
  result <- character(length(mean_vals))
  for (i in 1:length(mean_vals)) {
    mean_val <- mean_vals[i]
    sd_val <- sd_vals[i]
    if (is.na(mean_val)) {
      result[i] <- "--"
    } else if (is.na(sd_val) || sd_val == 0) {
      result[i] <- paste0(mean_val, unit)
    } else {
      result[i] <- paste0(mean_val, " ± ", sd_val, unit)
    }
  }
  return(result)
}

# ============================================================
# LaTeX table generation
# ============================================================

generate_complete_latex_table <- function(results_df, output_file = "benchmark_results_complete_working.tex") {
  if (!dir.exists(output_path)) {
    dir.create(output_path, recursive = TRUE)
  }
  full_output_path <- file.path(output_path, output_file)
  results_df <- results_df %>%
    mutate(
      Successful_GET_formatted = format_value_with_std(Successful_GET_mean, Successful_GET_sd),
      Successful_POST_formatted = format_value_with_std(Successful_POST_mean, Successful_POST_sd),
      Failed_GET_formatted = format_value_with_std(Failed_GET_mean, Failed_GET_sd),
      Failed_POST_formatted = format_value_with_std(Failed_POST_mean, Failed_POST_sd),
      Availability_formatted = format_value_with_std(Availability_mean, Availability_sd, "\\%"),
      Migration_Time_formatted = format_value_with_std(Migration_Time_mean, Migration_Time_sd, " s"),
      Downtime_formatted = format_value_with_std(Downtime_mean, Downtime_sd, " s")
    )
  results_df <- results_df %>%
    arrange(match(Connectivity_Tool, c(connectivity_tools, "idle")), 
            match(Database, databases),
            match(Deployment, db_types),
            Forwarding_Tool)
  sink(full_output_path)
  cat("\\begin{table}[tb]\n")
  cat("  \\caption{Benchmark Results: Request Counts, Availability, Migration Time and Downtime}\n")
  cat("  \\label{tab:benchmark_results_complete_working}\n")
  cat("  \\resizebox{\\linewidth}{!}{%\n")
  cat("    \\begin{tabular}{@{}lll l cccc ccc@{}}\n")
  cat("      \\toprule\n")
  cat("      \\multirow{2}{*}{\\textbf{Connectivity Tool}} & \\multirow{2}{*}{\\textbf{Database}} & \\multirow{2}{*}{\\textbf{Deployment}} & \\multirow{2}{*}{\\textbf{Forwarding Tool}} \n")
  cat("        & \\multicolumn{4}{c}{\\textbf{Request Counts}} & \\multicolumn{3}{c}{\\textbf{Performance Metrics}} \\\\\n")
  cat("      \\cmidrule(lr){5-8} \\cmidrule(lr){9-11}\n")
  cat("        &  &  &  & \\textbf{Successful} & \\textbf{Successful} & \\textbf{Failed} & \\textbf{Failed} & \\textbf{Availability} & \\textbf{Migration} & \\textbf{Downtime} \\\\\n")
  cat("        &  &  &  & \\textbf{GET} & \\textbf{POST} & \\textbf{GET} & \\textbf{POST} & \\textbf{(\\%)} & \\textbf{Time (s)} & \\textbf{(s)} \\\\\n")
  cat("      \\midrule\n\n")
  current_connectivity <- ""
  current_database <- ""
  for (i in 1:nrow(results_df)) {
    row <- results_df[i, ]
    conn_display <- if (row$Connectivity_Tool == "idle") "Idle" else names(conn_labels)[conn_labels == row$Connectivity_Tool]
    if (is.na(conn_display) || conn_display == "") conn_display <- row$Connectivity_Tool
    db_display <- names(db_labels)[db_labels == row$Database]
    deploy_display <- names(type_labels)[type_labels == row$Deployment]
    conn_rows <- results_df %>% filter(Connectivity_Tool == row$Connectivity_Tool) %>% nrow()
    db_rows <- results_df %>% filter(Connectivity_Tool == row$Connectivity_Tool, Database == row$Database) %>% nrow()
    if (current_connectivity != row$Connectivity_Tool) {
      cat("      \\multirow{", conn_rows, "}{*}{", conn_display, "}\n", sep = "")
      current_connectivity <- row$Connectivity_Tool
      current_database <- ""
    } else {
      cat("      ")
    }
    if (current_database != row$Database) {
      cat("        & \\multirow{", db_rows, "}{*}{", db_display, "}\n", sep = "")
      current_database <- row$Database
    } else {
      cat("        &                                   ")
    }
    cat("          & ", deploy_display, "    & ", row$Forwarding_Tool, " & ", 
        row$Successful_GET_formatted, " & ", 
        row$Successful_POST_formatted, " & ", 
        row$Failed_GET_formatted, " & ", 
        row$Failed_POST_formatted, " & ", 
        row$Availability_formatted, " & ", 
        row$Migration_Time_formatted, " & ", 
        row$Downtime_formatted, " \\\\\n", sep = "")
    next_row_exists <- i < nrow(results_df)
    if (next_row_exists) {
      next_row <- results_df[i + 1, ]
      if (row$Connectivity_Tool == next_row$Connectivity_Tool && 
          row$Database != next_row$Database) {
        cat("        \\cmidrule(lr){2-11}\n")
      }
    }
    if (next_row_exists) {
      next_row <- results_df[i + 1, ]
      if (row$Connectivity_Tool != next_row$Connectivity_Tool) {
        cat("      \\midrule\n\n")
      }
    }
  }
  cat("      \\bottomrule\n")
  cat("    \\end{tabular}\n")
  cat("  }\n")
  cat("\\end{table}\n")
  sink()
  cat("✓ Complete LaTeX table written to:", full_output_path, "\n")
}

# ============================================================
# Slim response time table generation
# ============================================================

generate_slim_response_time_table <- function(results_df, output_file = "response_time_table_slim.tex") {
  if (!dir.exists(output_path)) {
    dir.create(output_path, recursive = TRUE)
  }
  full_output_path <- file.path(output_path, output_file)
  results_df <- results_df %>%
    mutate(
      Response_Time_GET_formatted = format_value_with_std(Response_Time_GET_mean, Response_Time_GET_sd, " ms"),
      Response_Time_POST_formatted = format_value_with_std(Response_Time_POST_mean, Response_Time_POST_sd, " ms")
    ) %>%
    arrange(match(Connectivity_Tool, c(connectivity_tools, "idle")), 
            match(Database, databases),
            match(Deployment, db_types),
            Forwarding_Tool)
  results_df <- results_df %>%
    mutate(
      Connectivity_Display = case_when(
        Connectivity_Tool == "submariner" ~ "Submariner",
        Connectivity_Tool == "linkerd" ~ "Linkerd",
        Connectivity_Tool == "skupper" ~ "Skupper",
        Connectivity_Tool == "idle" ~ "Idle",
        TRUE ~ Connectivity_Tool
      ),
      Database_Display = case_when(
        Database == "postgres" ~ "PostgreSQL",
        Database == "mongo" ~ "MongoDB",
        TRUE ~ Database
      ),
      Deployment_Display = case_when(
        Deployment == "operator" ~ "Operator",
        Deployment == "stateful" ~ "StatefulSet",
        TRUE ~ Deployment
      ),
      Scenario = paste(Connectivity_Display, Database_Display, Deployment_Display, Forwarding_Tool, sep = " + ")
    )
  sink(full_output_path)
  cat("\\begin{table}[tb]\n")
  cat("  \\caption{Response Time Comparison Across Connectivity Tools and Configurations}\n")
  cat("  \\label{tab:response_time_comparison}\n")
  cat("  \\centering\n")
  cat("  \\resizebox{\\linewidth}{!}{%\n")
  cat("    \\begin{tabular}{@{}l", rep("c", nrow(results_df)), "@{}}\n", sep = "")
  cat("      \\toprule\n")
  cat("      \\textbf{Request Type}")
  for (i in 1:nrow(results_df)) {
    scenario_parts <- strsplit(results_df$Scenario[i], " \\+ ")[[1]]
    short_scenario <- paste0(
      substr(scenario_parts[1], 1, 3), "-",
      substr(scenario_parts[2], 1, 4), "-",
      substr(scenario_parts[3], 1, 3), "-",
      substr(scenario_parts[4], 1, 4)
    )
    cat(" & \\rotatebox{45}{\\textbf{", short_scenario, "}}", sep = "")
  }
  cat(" \\\\\n")
  cat("      ")
  for (i in 1:nrow(results_df)) {
    if (i == 1) cat(" & ")
    else cat(" & ")
    cat("\\tiny{", gsub(" \\+ ", "+", results_df$Scenario[i]), "}", sep = "")
  }
  cat(" \\\\\n")
  cat("      \\midrule\n")
  cat("      \\textbf{GET Requests (ms)}")
  for (i in 1:nrow(results_df)) {
    cat(" & ", results_df$Response_Time_GET_formatted[i], sep = "")
  }
  cat(" \\\\\n")
  cat("      \\textbf{POST Requests (ms)}")
  for (i in 1:nrow(results_df)) {
    cat(" & ", results_df$Response_Time_POST_formatted[i], sep = "")
  }
  cat(" \\\\\n")
  cat("      \\bottomrule\n")
  cat("    \\end{tabular}\n")
  cat("  }\n")
  cat("  \\begin{tablenotes}\n")
  cat("    \\small\n")
  cat("    \\item Note: Values shown as mean ± standard deviation across 3 runs. \"--\" indicates missing data.\n")
  cat("    \\item Abbreviations: Sub=Submariner, Link=Linkerd, Sku=Skupper, Idle=Idle, Post=PostgreSQL, Mong=MongoDB, Ope=Operator, Sta=StatefulSet, Clus=Clustershift\n")
  cat("  \\end{tablenotes}\n")
  cat("\\end{table}\n")
  sink()
  cat("✓ Slim response time table written to:", full_output_path, "\n")
}

# ============================================================
# Vertical layout response time table
# ============================================================

generate_vertical_response_time_table <- function(results_df, output_file = "response_time_table_vertical.tex") {
  if (!dir.exists(output_path)) {
    dir.create(output_path, recursive = TRUE)
  }
  full_output_path <- file.path(output_path, output_file)
  results_df <- results_df %>%
    mutate(
      Response_Time_GET_formatted = format_value_with_std(Response_Time_GET_mean, Response_Time_GET_sd, " ms"),
      Response_Time_POST_formatted = format_value_with_std(Response_Time_POST_mean, Response_Time_POST_sd, " ms")
    ) %>%
    arrange(match(Connectivity_Tool, c(connectivity_tools, "idle")), 
            match(Database, databases),
            match(Deployment, db_types),
            Forwarding_Tool)
  results_df <- results_df %>%
    mutate(
      Connectivity_Display = case_when(
        Connectivity_Tool == "submariner" ~ "Submariner",
        Connectivity_Tool == "linkerd" ~ "Linkerd",
        Connectivity_Tool == "skupper" ~ "Skupper",
        Connectivity_Tool == "idle" ~ "Idle",
        TRUE ~ Connectivity_Tool
      ),
      Database_Display = case_when(
        Database == "postgres" ~ "PostgreSQL",
        Database == "mongo" ~ "MongoDB",
        TRUE ~ Database
      ),
      Deployment_Display = case_when(
        Deployment == "operator" ~ "Operator",
        Deployment == "stateful" ~ "StatefulSet",
        TRUE ~ Deployment
      )
    )
  sink(full_output_path)
  cat("\\begin{table}[tb]\n")
  cat("  \\caption{Response Time Analysis by Configuration and Request Type}\n")
  cat("  \\label{tab:response_time_vertical}\n")
  cat("  \\centering\n")
  cat("  \\begin{tabular}{@{}llllcc@{}}\n")
  cat("    \\toprule\n")
  cat("    \\textbf{Connectivity} & \\textbf{Database} & \\textbf{Deployment} & \\textbf{Forwarding} & \\textbf{GET Response} & \\textbf{POST Response} \\\\\n")
  cat("    \\textbf{Tool} & & \\textbf{Type} & \\textbf{Tool} & \\textbf{Time (ms)} & \\textbf{Time (ms)} \\\\\n")
  cat("    \\midrule\n")
  current_connectivity <- ""
  current_database <- ""
  for (i in 1:nrow(results_df)) {
    row <- results_df[i, ]
    conn_rows <- results_df %>% filter(Connectivity_Tool == row$Connectivity_Tool) %>% nrow()
    db_rows <- results_df %>% filter(Connectivity_Tool == row$Connectivity_Tool, Database == row$Database) %>% nrow()
    if (current_connectivity != row$Connectivity_Tool) {
      cat("    \\multirow{", conn_rows, "}{*}{", row$Connectivity_Display, "}", sep = "")
      current_connectivity <- row$Connectivity_Tool
      current_database <- ""
    } else {
      cat("    ")
    }
    if (current_database != row$Database) {
      cat(" & \\multirow{", db_rows, "}{*}{", row$Database_Display, "}", sep = "")
      current_database <- row$Database
    } else {
      cat(" & ")
    }
    cat(" & ", row$Deployment_Display, 
        " & ", row$Forwarding_Tool,
        " & ", row$Response_Time_GET_formatted,
        " & ", row$Response_Time_POST_formatted, " \\\\\n", sep = "")
    next_row_exists <- i < nrow(results_df)
    if (next_row_exists) {
      next_row <- results_df[i + 1, ]
      if (row$Connectivity_Tool == next_row$Connectivity_Tool && 
          row$Database != next_row$Database) {
        cat("    \\cmidrule(lr){2-6}\n")
      }
    }
    if (next_row_exists) {
      next_row <- results_df[i + 1, ]
      if (row$Connectivity_Tool != next_row$Connectivity_Tool) {
        cat("    \\midrule\n")
      }
    }
  }
  cat("    \\bottomrule\n")
  cat("  \\end{tabular}\n")
  cat("  \\begin{tablenotes}\n")
  cat("    \\small\n")
  cat("    \\item Note: Response times shown as mean ± standard deviation across 3 experimental runs.\n")
  cat("    \\item \"--\" indicates scenarios where data collection was incomplete.\n")
  cat("  \\end{tablenotes}\n")
  cat("\\end{table}\n")
  sink()
  cat("✓ Vertical response time table written to:", full_output_path, "\n")
}

# ============================================================
# Main execution
# ============================================================

cat("=== BENCHMARK ANALYSIS WITH WORKING JSON STRUCTURE HANDLING ===\n")
cat("Current Date and Time (UTC - YYYY-MM-DD HH:MM:SS formatted):", format(Sys.time(), "%Y-%m-%d %H:%M:%S"), "\n")
cat("Base path:", base_path, "\n")
cat("Output path:", output_path, "\n")
cat("WORKING: Handles the actual JSON structure we're getting from jsonlite\n")
cat("WORKING: Uses estimation for downtime when detailed success/failure data unavailable\n\n")

results <- process_all_benchmarks()

if (nrow(results) > 0) {
  cat("\n=== FINAL RESULTS WITH WORKING STRUCTURE HANDLING ===\n")
  cat("Total scenarios processed:", nrow(results), "\n")
  complete_scenarios <- sum(!is.na(results$Availability_mean))
  missing_scenarios <- sum(is.na(results$Availability_mean))
  cat("Complete scenarios (with 3 runs):", complete_scenarios, "\n")
  cat("Missing scenarios (with '--' values):", missing_scenarios, "\n\n")
  cat("\n=== GENERATING SLIM RESPONSE TIME TABLES ===\n")
  generate_slim_response_time_table(results)
  generate_vertical_response_time_table(results)
  cat("=== MIGRATION TIME AND DOWNTIME SUMMARY ===\n")
  timing_data <- results %>% 
    filter(!is.na(Migration_Time_mean) | !is.na(Downtime_mean)) %>%
    select(Connectivity_Tool, Database, Deployment, Forwarding_Tool, 
           Migration_Time_mean, Migration_Time_sd, Downtime_mean, Downtime_sd) %>%
    arrange(Downtime_mean)
  if (nrow(timing_data) > 0) {
    print(timing_data)
    migration_data <- timing_data[!is.na(timing_data$Migration_Time_mean), ]
    if (nrow(migration_data) > 0) {
      cat("\nMigration time range:", min(migration_data$Migration_Time_mean), "s to", 
          max(migration_data$Migration_Time_mean), "s\n")
      cat("Average migration time:", round(mean(migration_data$Migration_Time_mean), 2), "s\n")
    }
    downtime_data <- timing_data[!is.na(timing_data$Downtime_mean), ]
    if (nrow(downtime_data) > 0) {
      cat("Downtime range:", min(downtime_data$Downtime_mean), "s to", 
          max(downtime_data$Downtime_mean), "s\n")
      cat("Average downtime:", round(mean(downtime_data$Downtime_mean), 2), "s\n")
    } else {
      cat("No downtime data calculated\n")
    }
  } else {
    cat("No timing data found!\n")
  }
  generate_complete_latex_table(results)
  csv_path <- file.path(output_path, "benchmark_results_working.csv")
  write.csv(results, csv_path, row.names = FALSE)
  cat("✓ Complete results saved as CSV:", csv_path, "\n")
} else {
  cat("\n✗ No results found.\n")
}

cat("\nAnalysis complete with working structure handling! 📊\n")