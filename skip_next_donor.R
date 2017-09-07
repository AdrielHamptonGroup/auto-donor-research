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
research_status_factory <- function (dbsrc) {
  tbl(dbsrc, "donor_research_states") %>%
    collect() %>% 
    with(setNames(donor_research_state_id, description)) ->
    states
  last_state_set <- NA
  list(
    set_status = function (db, donor_id, state) {
      state_id <- states[state]
      stopifnot(length(na.omit(donor_id)) == 1,
                length(na.omit(state_id)) == 1)
      last_state_set <<- state
      dbExecute(db, paste(
        "update donors set research_status =", state_id,
        "where donor_id =", donor_id
      ))
    },
    get_last_state = function () { last_state_set },
    states = states
  )
} 
tryCatch({
  research_states <- research_status_factory(src)
  donors <- tbl(src, "donors")
  next_donor_query <- donors %>%
    filter(
      research_status == !!unname(research_states$states["Not researched"])
    ) %>% head(1)
  next_donor <- next_donor_query %>% collect()
  cat("Skipping donor", next_donor$donor_id, next_donor$firstname, 
      next_donor$lastname1, next_donor$state1)
  research_states$set_status(dbi, next_donor$donor_id, "Research complete")
  cat("Done\n")
}, finally = {
  cat("\nDisconnecting from Database\n")
  dbDisconnect(dbi)
})