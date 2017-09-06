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
tryCatch({
  donors <- tbl(src, "donors")
  donor_receipt_link <- tbl(src, "donor_receipt_link")
  incomplete_donors <- donors %>%
    filter(research_status == 2) %>%
    select(donor_id) %>% 
    collect()
  if(nrow(incomplete_donors) == 0) {
    stop("No incomplete research found")
  }
  cat("Clearing researched status for ", nrow(incomplete_donors), " donors: ")
  dbExecute(dbi, paste0(
    "update donors set research_status = 1 where donor_id in (",
    paste(incomplete_donors$donor_id, collapse = ","), ")"
  ))
  cat("Done\n")
}, finally = {
  cat("\nDisconnecting from Database\n")
  dbDisconnect(dbi)
})