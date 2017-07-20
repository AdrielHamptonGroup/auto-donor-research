suppressMessages({
  library(tidyverse)
  library(httr)
  library(jsonlite)
  library(DBI)
  library(RMySQL)
})
.secrets <- readLines(".secrets") %>% paste(collapse = "\n") %>% fromJSON()
if (any(.secrets[c("fec_api_key", "jaffe_db_pw", "jaffe_db_usr",
                   "jaffe_db_uri", "jaffe_db_port")] %>% sapply(is.null))) {
  stop("Connection info missing from .secrets file")
}
src <- with(.secrets, src_mysql("jaffe_db", jaffe_db_uri, jaffe_db_port, 
                                jaffe_db_usr, jaffe_db_pw))
dbi <- src$con
# for marking people with no reults as researched
null_receipt_id <- 32768
tryCatch({
  donors <- tbl(src, "donors")
  donor_receipt_link <- tbl(src, "donor_receipt_link")
  next_donor_query <- donors %>%
    anti_join(donor_receipt_link, by = "donor_id") %>% head(1)
  next_donor <- next_donor_query %>% collect()
  cat("Skipping donor", next_donor$donor_id, next_donor$firstname, 
      next_donor$lastname1, next_dono$state1)
  tibble(donor_id = next_donor$donor_id[1], 
         receipt_id = null_receipt_id) %>%
    dbWriteTable(dbi, "donor_receipt_link", .,
                 append = TRUE, row.names = FALSE)
  cat("Done\n")
}, finally = {
    cat("\nDisconnecting from Database\n")
    dbDisconnect(dbi)
})