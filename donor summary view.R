src <- connect_to_amazon(use_dplyr = TRUE)
db <- connect_to_amazon()

tagged_receipts <- tbl(src, sql("
select drl.donor_id, r.*, c.designation_full committee_type, c.party_full party
from donor_receipt_link as drl
  inner join contribution_receipts r on drl.receipt_id = r.receipt_id
  inner join committees c on r.committee_id  = c.committee_id
"))

tagged_receipts %>% 
  group_by(donor_id, party) %>%
  summarize(total = sum(contribution_receipt_amount)) %>%
  ungroup() ->
  party_summary

tagged_receipts %>%
  mutate(primary = ifelse(
    committee_type == "Principal campaign committee" &
      fec_election_type_desc %in% c("PRIMARY", "RUNOFF"),
    TRUE,
    FALSE
  )) %>%
  group_by(donor_id, committee_name, primary) %>%
  summarize(total = sum(contribution_receipt_amount),
            number = sum(!is.na(contribution_receipt_amount)),
            initial = min(contribution_receipt_date)) %>%
  ungroup() ->
  candidate_summary

# widen summary data through repeat joins
donor_summary <- tbl(src, "donors") %>%
  #select(donor_id, firstname, lastname1) %>%
  left_join(
    party_summary %>% filter(party == "DEMOCRATIC PARTY") %>% 
      select(donor_id, democrats_total = total), 
    by = "donor_id")  %>%
  left_join(
    party_summary %>% filter(party == "REPUBLICAN PARTY") %>%
      select(donor_id, republicans_total = total),
    by = "donor_id") %>%
  left_join(
    party_summary %>% filter(
      !is.na(party),
      !party %in% c("REPUBLICAN PARTY", "DEMOCRATIC PARTY")
    ) %>%
      group_by(donor_id) %>%
      summarize(total = sum(total)) %>%
      ungroup() %>%
      select(donor_id, other_party_total = total),
    by = "donor_id") %>%
  left_join(
    party_summary %>% filter(is.na(party)) %>%
      select(donor_id, pacs_total = total),
    by = "donor_id") %>%
  left_join(
    candidate_summary %>% filter(committee_name == "BERNIE 2016") %>%
      select(donor_id, bernie_total = total, bernie_number = number,
             bernie_first = initial),
    by = "donor_id"
  ) %>%
  left_join(
    candidate_summary %>%
      filter(committee_name == "HILLARY FOR AMERICA", primary == 1) %>%
      select(donor_id, hillary_primary_total = total,
             hillary_primary_number = number,
             hillary_primary_first = initial),
    by = "donor_id"
  ) %>%
  left_join(
    candidate_summary %>%
      filter(committee_name == "HILLARY FOR AMERICA", primary == 0) %>%
      select(donor_id, hillary_general_total = total,
             hillary_general_number = number),
    by = "donor_id"
  ) %>%
  select(-donor_id)
donor_summary %>%
  sql_render() %>%
  paste("create or replace view donor_summary as", .) %>%
  sqlQuery(db, .)

# test the view 
sqlQuery(db, "Select * from donor_summary limit 50") %>% View 
