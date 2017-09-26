suppressMessages(suppressWarnings({
  library(tidyverse)
  library(DBI)
  library(RMySQL)
  library(jsonlite)
  library(accurateappendr)
}))
.secrets <- readLines(".secrets") %>% paste(collapse = "\n") %>% fromJSON()
if (any(.secrets[c("fec_api_key", "jaffe_db_pw", "jaffe_db_usr",
                   "jaffe_db_uri", "jaffe_db_port", 
                   "accurate_append_key")] %>% sapply(is.null))) {
  stop("Connection info missing from .secrets file")
}
cl_args <- commandArgs(trailingOnly = TRUE)
limit <- NA
limit_pos <- grep("limit", cl_args, ignore.case = TRUE)
if (length(limit_pos)) {
  limit <- gsub("limit=", "", cl_args[limit_pos[1]]) %>% as.numeric()
  cat("Limiting: will stop after", limit, "donors\n")
}
donor_list <- NA
donor_list_pos <- setdiff(seq_along(cl_args), limit_pos)[1]
if (is.na(donor_list_pos)) {
  stop("Must specify filename for donor_id list csv")
}
donor_list_csv <- read_csv(cl_args[donor_list_pos])
donor_list <- donor_list_csv$donor_id
if (is.null(donor_list)) {
  donor_list <- donor_list_csv[[match("integer", sapply(donor_list_csv, class))]]
}
if (!is.numeric(donor_list)) {
  stop("donor_id column not found in input file")
}
src <- with(.secrets, src_mysql("jaffe_db", jaffe_db_uri, jaffe_db_port, 
                                jaffe_db_usr, jaffe_db_pw))
dbi <- src$con

lookup_status_factory <- function (dbsrc) {
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
        "update donors set accurate_append_status =", state_id,
        "where donor_id =", donor_id
      ))
    },
    get_last_state = function () { last_state_set },
    states = states
  )
} 
tryCatch({
  donors <- copy_to(src, tibble(donor_id = donor_list), "temp_donor_list")
  db_donors <- tbl(src, "donors")
  lookup_states <- lookup_status_factory(src)
  next_donor_query <- db_donors %>%
    inner_join(donors, by = "donor_id") %>%
    filter(accurate_append_status == 
             !!unname(lookup_states$states["Not researched"]),
           is.na(phone1))
  cat("Remaining donors needing accurate append lookup:",
      next_donor_query %>% summarize(n = n()) %>% collect() %>% 
        magrittr::extract2("n"), "\n")
  next_donor_query <- next_donor_query %>% head(1)
  next_donor <- next_donor_query %>% collect()
  count <- 0
  while(nrow(next_donor) && (is.na(limit) || count < limit)) {
    count <- count + 1
    # mark donor so parallel scripts will skip it
    lookup_states$set_status(dbi, next_donor$donor_id, "In progress")
    cat(next_donor$firstname, next_donor$lastname1, 
        next_donor$donor_id, ":")
    # not enough info for a phone search? try reverse email
    addresses <- next_donor %>%
      select(first_name = firstname, last_name = lastname1, address = address1,
             city = city1, state = state1, zip = zip1) %>%
      filter(complete.cases(select(., -zip)))
    known_addresses <- addresses
    if (!sum(complete.cases(addresses))) {
      if (is.na(next_donor$email1)) {
        cat("No address or email on file. Skipping\n")
        lookup_states$set_status(dbi, next_donor$donor_id, "Research complete")
        next_donor <- next_donor_query %>% collect()
        next
      }
      res <- reverse_email(.secrets$accurate_append_key, next_donor$email1)
      addresses <- select(res, first_name, last_name, address, city, state, zip)
    }
    addresses <- filter(addresses, complete.cases(select(addresses, -zip)))
    if (!nrow(addresses)) {
      cat("No addresses on file. Zero reverse email results. Skipping\n")
      lookup_states$set_status(dbi, next_donor$donor_id, "Research complete")
      next_donor <- next_donor_query %>% collect()
      next
    }
    new_phones <- tibble()
    apply(addresses, 1, function(x) { 
      res <- consumer_phone(.secrets$accurate_append_key, x["first_name"], 
                            x["last_name"], x["address"], x["city"], 
                            x["state"])
      if (nrow(res)) {
        new_phones <<- bind_rows(new_phones, res)
      } 
    })
    new_addresses <- setdiff(addresses, known_addresses)
    if (nrow(new_addresses)) {
      cat(nrow(new_addresses), "new addresses.")
      new_addresses %>%
        distinct() %>%
        select(line1 = address, city, state, zip) %>%
        mutate(donor_id = next_donor$donor_id) %>%
        dbWriteTable(conn = dbi, name = "donor_addresses", value = .,
                     append = TRUE, overwrite = FALSE, row.names = FALSE)
    }
    cat(nrow(new_phones), "new phone numbers.")
    if (nrow(new_phones)) {
      new_phones %>%
        distinct() %>%
        select(phone_number = phone, line_type = phone_type, match_level,
               max_match_level = max_validation_level, source) %>%
        mutate(donor_id = next_donor$donor_id) %>%
        dbWriteTable(conn = dbi, name =  "donor_phones", value = ., 
                     overwrite = FALSE, append = TRUE, row.names = FALSE)
    }
    lookup_states$set_status(dbi, next_donor$donor_id, "Research complete")
    cat("Done\n")
    next_donor <- next_donor_query %>% collect()
  }
}, finally = {
  # revert if error occured mid-research
  if (exists("next_donor") && exists("lookup_states") &&
      lookup_states$get_last_state() == "In progress") {
    if(dbIsValid(dbi)) {
      cat("Reverting status to 'Not researched' for donor_id:", 
          next_donor$donor_id)
      lookup_states$set_status(dbi, next_donor$donor_id, "Not researched")
    } else {
      cat("donor_id:", next_donor$donor_id, " needs to be reset, but ",
          "database is not available.")
    }
  }
  cat("\nDisconnecting from Database\n")
  dbDisconnect(dbi)
})
