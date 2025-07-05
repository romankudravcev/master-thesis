# Read CSV files
read_and_prepare_data <- function(db_path, client_path) {
  # Read database data
  db_data <- read.csv(db_path)
  db_data$created_at <- as.POSIXct(db_data$created_at, format="%Y-%m-%dT%H:%M:%OS", tz="UTC")
  
  # Read client data
  client_data <- read.csv(client_path)
  client_data$timestamp <- as.POSIXct(client_data$message.timestamp, format="%Y-%m-%dT%H:%M:%OS", tz="UTC")
  client_data$method <- client_data$message.method
  client_data$content <- client_data$message.content
  client_data$success <- as.logical(client_data$success)
  
  return(list(db_data = db_data, client_data = client_data))
}

# Time window filter (only applied to client data)
filter_time_window <- function(data, timestamp_col) {
  ref_time <- min(data[[timestamp_col]])
  elapsed_minutes <- as.numeric(difftime(data[[timestamp_col]], ref_time, units="mins"))
  data[elapsed_minutes > 1 & elapsed_minutes <= 6,]  # Capture the next 5 minutes (1-6)
}

# Format timestamp
format_timestamp <- function(ts) {
  strftime(ts, "%Y-%m-%d %H:%M:%S", tz="UTC")
}

# Analyze requests
analyze_system_health <- function(db_data, client_data, current_time, current_user) {
  # Apply time window filter to the client data only
  filtered_client_data <- filter_time_window(client_data, "timestamp")
  
  # GET request analysis
  get_requests <- filtered_client_data[filtered_client_data$method == "GET",]
  total_gets <- sum(filtered_client_data$method == "GET")
  failed_gets <- sum(!get_requests$success)
  get_failure_rate <- round(failed_gets / total_gets * 100, 2)
  
  # POST request analysis
  post_requests <- filtered_client_data[filtered_client_data$method == "POST",]
  total_posts <- sum(filtered_client_data$method == "POST")
  
  # Debug print
  cat("Debug - Checking POST requests:\n")
  missing_in_db <- logical(nrow(post_requests))
  for(i in 1:nrow(post_requests)) {
    post_content <- post_requests$content[i]
    # Check if the POST content exists in DB
    is_missing <- !any(db_data$content == post_content)
    missing_in_db[i] <- is_missing
    if(is_missing) {
      cat("POST request content not found in DB:\n")
      cat("Timestamp:", format_timestamp(post_requests$timestamp[i]), "UTC\n")
      cat("Content:", post_content, "\n\n")
    }
  }
  
  failed_posts <- sum(missing_in_db)
  post_failure_rate <- round(failed_posts / total_posts * 100, 2)
  
  # Total request analysis
  total_requests <- nrow(filtered_client_data)
  total_failed <- failed_gets + failed_posts
  total_failure_rate <- round(total_failed / total_requests * 100, 2)
  
  # Get failed GET request timestamps
  failed_get_timestamps <- get_requests$timestamp[!get_requests$success]
  
  # Get failed POST request timestamps (those missing in DB)
  failed_post_timestamps <- post_requests$timestamp[missing_in_db]
  
  # Combine all failed timestamps
  failed_timestamps <- sort(c(failed_get_timestamps, failed_post_timestamps))
  
  #cat("Failed Requests:\n")
  #cat("GET failures:\n")
  #if(length(failed_get_timestamps) > 0) {
  #  for(ts in failed_get_timestamps) {
  #    cat(sprintf("- %s UTC\n", format_timestamp(ts)))
  #  }
  #} else {
  #  cat("None\n")
  #}
  #
  #cat("\nPOST failures (missing in DB):\n")
  #if(length(failed_post_timestamps) > 0) {
  #  for(ts in failed_post_timestamps) {
  #    cat(sprintf("- %s UTC\n", format_timestamp(ts)))
  #  }
  #} else {
  #  cat("None\n")
  #}
  
  if(length(failed_timestamps) > 0) {
    cat("\nDowntime Period:\n")
    start_time <- min(failed_timestamps)
    end_time <- max(failed_timestamps)
    duration <- as.numeric(difftime(end_time, start_time, units="secs"))
    
    cat(sprintf("Start: %s UTC\n", format_timestamp(start_time)))
    cat(sprintf("End: %s UTC\n", format_timestamp(end_time)))
    cat(sprintf("Duration: %.2f seconds\n", duration))
  } else {
    cat("\nNo downtime detected\n")
  }
  
  cat("\nRequest Statistics:\n")
  cat(sprintf("GET Requests: %d total, %d failed (%.2f%%)\n", 
              total_gets, failed_gets, get_failure_rate))
  cat(sprintf("POST Requests: %d total, %d failed (%.2f%%)\n", 
              total_posts, failed_posts, post_failure_rate))
  cat(sprintf("All Requests: %d total, %d failed (%.2f%%)\n", 
              total_requests, total_failed, total_failure_rate))
}

# Main execution
main <- function() {
  # Read data
  data <- read_and_prepare_data(
    "/Users/romankudravcev/Desktop/masterarbeit/benchmark_results/availability/database-state.csv", 
    "/Users/romankudravcev/Desktop/masterarbeit/benchmark_results/availability/client-state.csv"
  )
  
  # Perform analysis
  analyze_system_health(data$db_data, data$client_data, current_time, current_user)
}

# Run the analysis
main()

