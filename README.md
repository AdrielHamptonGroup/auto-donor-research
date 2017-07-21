# Automated Donor Research

Scripts for our automated donor research process using R and the openFEC web
API.

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
   they will be included in the `donor_sumarry` view. 
   
#### Usage

Run from the command prompt.

```
Rscript auto_donor_research.R
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


### db setup.R

A log of all the sql commands I've used to create the database. It does not
contain connection info and is not setup to be run unsupervised, but is 
included so that the db could be reproduced if lost

### donor summary view.R

This is the script used to build or modify the donor summary view. You
don't need this to access the view (just `select * from donor_summary`), 
but this would allow you to recreate it if it is lost. 

