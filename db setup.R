# donors
sqlQuery(db, "CREATE TABLE `donors`  (`donor_id` integer NOT NULL AUTO_INCREMENT PRIMARY KEY, `firstname` varchar(255), `middlename` varchar(255), `lastname1` varchar(255), `lastname2` varchar(255), `email1` varchar(255), `email2` varchar(255), `address1` varchar(255), `city1` varchar(255), `state1` varchar(255), `zip1` varchar(255), `address2` varchar(255), `city2` varchar(255), `state2` varchar(255), `zip2` varchar(255), `phone1` varchar(255), `phone2` varchar(255), `twitter` varchar(255), `facebook` varchar(255), `linkedin` varchar(255), `instagram` varchar(255), `referral` varchar(255), `occupation` varchar(255), `employer1` varchar(255), `employer2` varchar(255), `shortname` varchar(255), `familyoffice` varchar(255), `age` varchar(255), `race` varchar(255), `religion` varchar(255), `gender` varchar(255), `notes` varchar(255))")
sqlSave(db, people, "donors_temp",rownames = FALSE, verbose = FALSE)
sqlQuery(db, "insert into donors(firstname, middlename, lastname1, lastname2, email1, email2, address1, city1, state1, zip1, address2, city2, state2, zip2, phone1, phone2, twitter, facebook, linkedin, instagram, referral, occupation, employer1, employer2, shortname, familyoffice, age, race, religion, gender, notes) select firstname, middlename, lastname1, lastname2, email1, email2, address1, city1, state1, zip1, address2, city2, state2, zip2, phone1, phone2, twitter, facebook, linkedin, instagram, referral, occupation, employer1, employer2, shortname, familyoffice, age, race, religion, gender, notes from donors_temp")
sqlQuery(db, "drop table donors_temp")


sqlSave(db, clean_receipts, "contribution_receipts_temp", rownames = FALSE, 
        verbose = FALSE)
sqlSave(db, clean_receipts[seq(22581 + 1, nrow(clean_receipts)), ], 
        "contribution_receipts_temp", rownames = FALSE, 
        verbose = FALSE, append = TRUE, fast = TRUE)
receipts_table_sql <- sqlQuery(
  db, 
  "show create table contribution_receipts_temp"
)
receipts_table_sql$`Create Table`[1] %>%
  sub(
    "`contribution_receipts_temp` \\(", 
    paste("contribution_receipts \\( ", 
          "receipt_id integer NOT NULL AUTO_INCREMENT PRIMARY KEY,", sep = "\n"),
    .
  ) %>%
  sub("ENGINE=InnoDB DEFAULT CHARSET=latin$", "", .) %>% 
  sqlQuery(channel = db)
receipts_colnames <- sqlColumns(db, "contribution_receipts_temp")
receipts_colnames <- receipts_colnames$COLUMN_NAME %>% paste(collapse = ", ")
sqlQuery(db, paste0(
  "insert into contribution_receipts (", receipts_colnames, ")\n ",
  "select ", receipts_colnames, " from contribution_receipts_temp"
))

# fix date import
clean_receipts %>%
  transmute(receipt_id = as.numeric(row.names(.)), 
            contribution_receipt_date = as.character(contribution_receipt_date)) %>%
  sqlSave(db, ., "date_fix_temp", rownames = FALSE)
sqlQuery(db, "alter table contribution_receipts modify column contribution_receipt_date date")
sqlQuery(db, 
"update contribution_receipts as cr 
 inner join date_fix_temp as df on cr.receipt_id = df.receipt_id
 set cr.contribution_receipt_date = CAST(df.contribution_receipt_date as DATE)")

# link donors and receips
sql_file_query(db, "queries/create donor_receipt_link table.sql")
sql_file_query(db, "queries/link donors and receipts.sql")
# place to store extra receipts returned from FEC API with near-match names
sql_file_query(db, "queries/create name_mismach_receipts table.sql")

# extra comittee info
clean_committees <- clean_committees %>% 
  select(-treasurer_name, -cycle) %>%
  distinct()
sqlSave(db, clean_committees, "committees", rownames = FALSE, verbose = FALSE)
sqlQuery(db, "alter table committees modify column committee_id varchar(255) not null primary key first")

tibble(abb = state.abb, name = state.name) %>% 
  sqlSave(db, ., "states", rownames = FALSE, verbose = FALSE)
sqlQuery(db, "alter table states modify column abb varchar(2) not null primary key")
sqlQuery(db, "insert into states (abb, name) values ('DC', 'District of Columbia')")

dbExecute(dbi, "
  insert into contribution_receipts (contributor_name, committee_name)
  values ('no receiptsfound', 'no receipts found')")

# limited user acount for use in receipt processing
dbExecute(dbi, "create user 'auto_donor_reseearch' identified by '"REDACTED"' 
                PASSWORD EXPIRE NEVER")

dbExecute(dbi, "grant select, insert on jaffe_db.donor_receipt_link 
                to auto_donor_research")
dbExecute(dbi, "grant select, insert on jaffe_db.contribution_receipts 
                to auto_donor_research")
dbExecute(dbi, "grant select, insert on jaffe_db.donors 
                to auto_donor_research")
dbExecute(dbi, "grant select, insert on jaffe_db.committees 
                to auto_donor_research")
dbExecute(dbi, "grant select, insert on jaffe_db.name_mismatch_receipts 
                to auto_donor_research")
dbExecute(dbi, "grant select, insert on jaffe_db.foreign_addresses 
                to auto_donor_research")
dbExecute(dbi, "grant select on jaffe_db.states 
                to auto_donor_research")
dbExecute(dbi_admin, "grant select, drop on jaffe_db.donor_summary 
                      to auto_donor_research")
dbExecute(dbi_admin, "grant create view on jaffe_db.* 
                      to auto_donor_research")
