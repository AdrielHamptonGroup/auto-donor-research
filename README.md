# Automated Donor Research

Scripts for our automated donor research process using R and the openFEC web
API. This process retrieves past contribution receipts for donors that 
exist in our contact database. 

## News

September 26:

* Added command line arguments to `auto_donor_research.R`
* List `donor_id` in message for donors where no receipts were found

Setpember 7:
* Added a `reseach_status` flag to the `donors` table so `auto_donor_research`
  can mark when it begins researching a donor to allow multiple instances
  to run in parallel withoutn colliding. 
  * Robust error handling will revert this flag if an error occurs before
    uploading the receipt data
  * Unfortunately, this does not currently also detect when a script execution
    is manually aborted, see the new `clear_incomplete_research_flags` script
    below
  * If you would like a donor to be researched again, 
    (e.g. after correcting a name error) reset their 
    `research_status` to 1 ("Not researched"). 
* `auto_donor_research` automatically adjusts the API call rate based on the
  limit reported by the FEC api. This allows upgraded to keys to run at the
  120/min rate instead of the default 1000/hour. 
  [Info on upgrading your key](18F/openFEC#2569)

## Files

### auto_donor_reseearch.R

A script to automatically research new donors. 

1. Search for people in the `donors` table of the campaign database
   that haven't yet been researched
1. Retrieve their contribution receipts from the openFEC API
2. Find any unitemized contributions made through 3rd party payment systems 
   and create new receipts for them
3. Upload receipts to the `contribution_receipts` table of the campaign database 
4. Link them to the donor records through the `donor_receipt_link` table so that 
   they will be included in the `donor_summary` view. 
   
#### Usage

Run from the command prompt.

The following command line arguments are available:

Argument | Effect
--- | ---
`client_id=X` | Research only donors for the client whose database id is specified
`reverse` | Start from the highest `donor_id` and work backwards
`limit=X` | Stop after X donors have been reaserched (useful for testing because there is no clean way to interrup the script at this time)

```
Rscript auto_donor_research.R client=1 limit=1000 reverse
```

#### Requirements

1. Install R
2. Install R package dependencies (see `install_dependencies` below)
3. Include a `.secrets` json file in the same directory with connection
   information:
   
| variable name | contents |
| --- | --- |
| jaffe_db_uri | Address of database server |
| jaffe_db_port | Port for MySQL connection |
| jaffe_db_usr | login username |
| jaffe_db_pw | login password |
| fec_API_key | openFEC API key 

The `.secrets` file is not included in the repo. Contact @datatitian on slack
if you need it. If you need an openFEC API key, you can generate one at https://api.data.gov/signup/

### install_dependencies.R

Needs to be run one time to install R packages used in the 
`auto_donor_research.R`. I'm not sure if this will run smoothly from an Rscript call. 
It depends on whether the R installation is configured with a default library and repository.

### skip_next_donor.R

If `auto_donor_research` keeps failing on the first donor, there is probably 
something wrong with that donor record. Run this to skip that person and then
`auto_donor_research` will move on. 

#### Usage

```
Rscript skip_next_donor.R
```

Note that the FEC API incorrectly returns "502 Bad Gateway" for certain invalid
donor name patterns. If you see this error repeatedly, the `skip_next_donor`
script will fix the problem.

### clear_incomplete_research_flags.R

Find donors stuck in researched status limbo and reset them. Do not run unless
you know nobody is currently running the research script. 

#### Usage

```
Rscript clear_incomplete_research_flags.R
```

### db setup.R

A log of all the sql commands I've used to create the database. It does not
contain connection info and is not setup to be run unsupervised, but is 
included so that the db could be reproduced if lost

### donor summary view.R

This is the script used to build or modify the donor summary view. You
don't need this to access the view (just `select * from donor_summary`), 
but this would allow you to recreate it if it is lost. 

