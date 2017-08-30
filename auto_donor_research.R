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
FEC_api_Request <- function (quer) {
  uri <- "https://api.open.fec.gov/v1"
  ver <- "v1"
  meth <- "/schedules/schedule_a/"
  quer$api_key = .secrets$fec_api_key
  rate_limit_wait <- 30
  Sys.sleep(3.6) # 1000 requests per hour
  r <- GET(uri, path = c(ver, meth), query = quer)
  while(status_code(r) != 200) {
    if(rate_limit_wait > 480) {
      stop_for_status(r)
    }
    http_condition(r, type = "message") %>% message()
    print(paste("pausing", rate_limit_wait / 60, "min"))
    Sys.sleep(rate_limit_wait)
    rate_limit_wait <- rate_limit_wait * 2
    r <- GET(uri, path = c(ver, meth), query = quer)
  }
  cat(".")
  cont <- content(r, "text", encoding = "UTF-8") 
  out <- cont %>% fromJSON
  out
}
tryCatch({
  donors <- tbl(src, "donors")
  donor_receipt_link <- tbl(src, "donor_receipt_link")
  contribution_receipts <- tbl(src, "contribution_receipts")
  committees_table <- tbl(src, "committees")
  known_committees <- committees_table %>% 
    select(committee_id) %>%
    collect() %>%
    magrittr::extract2(1)
  next_donor_query <- donors %>%
    anti_join(donor_receipt_link, by = "donor_id") 
  cat("Remaining donors needing research:", 
      next_donor_query %>% summarize(n = n()) %>% collect() %>% 
      magrittr::extract2("n"), "\n")
  next_donor_query <- next_donor_query %>% head(1)
  next_donor <- next_donor_query %>% collect()
  while(nrow(next_donor)) {
    next_donor$firstname <- gsub("[^[:alpha:]]", "", next_donor$firstname)
    next_donor$lastname1 <- gsub("[^[:alpha:]]", "", next_donor$lastname1)
    if (is.na(next_donor$firstname[1]) | is.na(next_donor$lastname1[1]) |
        nchar(next_donor$lastname1[1]) < 2 | 
        tolower(next_donor$lastname1[1]) %in% c("na", "no") | 
        tolower(next_donor$firstname[1]) %in% c("na", "no") ) {
      cat("Insufficient info for donor_id:", next_donor$donor_id, "- Skipping\n")
      tibble(donor_id = next_donor$donor_id[1], 
             receipt_id = null_receipt_id) %>%
        dbWriteTable(dbi, "donor_receipt_link", .,
                     append = TRUE, row.names = FALSE)
      next_donor <- next_donor_query %>% collect()
      next
    }
    quer <-  list(
      contributor_type = "individual",
      two_year_transaction_period = 2016,
      is_individual = "true",
      per_page = 100,
      contributor_name = paste(
        tolower(next_donor$firstname[1]), 
        tolower(next_donor$lastname1[1]))
    )
    if(!is.na(next_donor$state1[1])) {
      quer$contributor_state <- next_donor$state1[1]
    }
    r_json <- FEC_api_Request(quer)
    if(r_json$pagination$count == 0) {
      # mark person as researched by linking to an empty receipt
      tibble(donor_id = next_donor$donor_id[1], 
             receipt_id = null_receipt_id) %>%
        dbWriteTable(dbi, "donor_receipt_link", .,
                     append = TRUE, row.names = FALSE)
      cat(" No receipts found for", quer$contributor_name, "\n")
      next_donor <- next_donor_query %>% collect()
      next
    }
    committees <- distinct(r_json$results$committee)
    receipts <- r_json$results %>% select(-committee, -contributor)
    page_num <- 2
    while(page_num <= r_json$pagination$pages) {
      quer$last_index <- r_json$pagination$last_indexes$last_index
      quer$last_contribution_receipt_date <- 
        r_json$pagination$last_indexes$last_contribution_receipt_date
      r_json <- FEC_api_Request(quer)
      if(length(r_json$results) == 0) {
        cat("FEC API pagination error on donor_id", next_donor$donor_id)
        break
      }
      receipts <- receipts %>%
        bind_rows(select(r_json$results, -committee, -contributor)) %>%
        distinct()
      committees <- committees %>% 
        bind_rows(r_json$results$committee) %>%
        distinct()
      page_num <- page_num + 1
    }
    ## clean and prep receipts for upload
    committees <- committees %>%
      mutate(candidate_ids = sapply(candidate_ids, function (x) {
        ifelse(length(x), x[[1]], NA_character_)
      })) %>%
      select(-cycles, -cycle, -treasurer_name) %>%
      distinct() 
    
    receipts <- receipts %>%
      distinct() %>%
      mutate(contribution_receipt_date = 
               as.Date(sub("T*$", "", contribution_receipt_date)),
             zip5 = substr(contributor_zip, 1, 5)) 
    
    ## handle earmarked contributions
    receipts$unitemized <- F
    if (any(!is.na(receipts$memo_text))) {
      # find earmaked contributions and extract destination committee
      earmk_reg <- regexec("ea?rma?r?ke?d? (for|to):? *(.*)", 
                           receipts$memo_text, ignore.case = T) %>%
        regmatches(x = receipts$memo_text)
      receipts$earmark_destination <- sapply(earmk_reg, `[`, i = 3)
      # isolate earmarked contributions without report from dest committee
      unitemized_earmarks <- receipts %>%
        mutate(earmark_temp = ifelse(
          is.na(earmark_destination), 
          committee_name,
          earmark_destination
        )) %>%
        group_by(contributor_name, contributor_occupation, 
                 contribution_receipt_date, contribution_receipt_amount, 
                 earmark_temp) %>%
        filter(n() == 1, any(!is.na(earmark_destination))) %>%
        ungroup %>%
        mutate(committee_id = NA, committee_name = earmark_destination,
               unitemized = T) %>%
        select(-earmark_temp)
      
      # add them back into receipt pool with destination committee in place of
      # PAC this inentionally leaves duplcate records of donations with both the
      # PAC and the candidate so we can track both candidate donations and PAC
      # earmarking as features
      receipts <- receipts %>%
        bind_rows(unitemized_earmarks) %>%
        select(-earmark_destination)
    }
    # cleanup for db
    receipts <- receipts %>%
      rename(contributor_zip5 = zip5) %>%
      select(
        contributor_name, contributor_city, 
        contributor_state, contributor_zip5, contributor_occupation, 
        contributor_employer, committee_name, contribution_receipt_amount, 
        contribution_receipt_date, memo_text, receipt_type_full, 
        unitemized, link_id, report_type, filing_form, line_number, 
        contributor_zip, schedule_type_full, contributor_middle_name, 
        contributor_prefix, contributor_last_name, committee_id, 
        contributor_suffix, original_sub_id, contributor_first_name, 
        report_year, memo_code, entity_type, back_reference_schedule_name, 
        entity_type_desc, contributor_id, fec_election_type_desc, 
        pdf_url, file_number, sub_id, contributor_aggregate_ytd, 
        amendment_indicator_desc, transaction_id, receipt_type, 
        fec_election_year, memoed_subtotal, two_year_transaction_period, 
        is_individual, load_date, image_number
      )

    ## write donor's receipts and links to the DB
    name_mismatches <- 
      tolower(receipts$contributor_first_name) != tolower(next_donor$firstname[1]) |
      tolower(receipts$contributor_last_name) != tolower(next_donor$lastname1[1])
    cat(" Uploading", sum(!name_mismatches), "receipts for", 
        next_donor$firstname, next_donor$lastname1, ": ")
    dbWriteTable(dbi, "contribution_receipts", receipts, 
                 append = TRUE, row.names = FALSE)
    first_new_key <- dbGetQuery(dbi, "select LAST_INSERT_ID()")[[1]]
    new_links <- tibble(
      donor_id = next_donor$donor_id[1],
      receipt_id = seq_len(nrow(receipts)) + first_new_key - 1
    )
    if (any(!name_mismatches)) {
      filter(new_links, !name_mismatches) %>%
        dbWriteTable(dbi, "donor_receipt_link", .,
                     append = TRUE, row.names = FALSE)
    } else {
      tibble(donor_id = next_donor$donor_id[1], 
             receipt_id = null_receipt_id) %>%
        dbWriteTable(dbi, "donor_receipt_link", .,
                     append = TRUE, row.names = FALSE)
    }
    if (any(name_mismatches)) {
      filter(new_links, name_mismatches) %>%
        dbWriteTable(dbi, "name_mismatch_receipts", .,
                     append = TRUE, row.names = FALSE)    
    }
    ## upload any new committees
    committees <- filter(committees, !committee_id %in% known_committees)
    if (nrow(committees)) {
      dbWriteTable(dbi, "committees", committees,
                   append = TRUE, row.names = FALSE)
      known_committees <- c(known_committees, committees$committee_id)
    }
    cat("Done\n")
    next_donor <- next_donor_query %>% collect()
  }
}, finally = {
  cat("\nDisconnecting from Database\n")
  dbDisconnect(dbi)
})
