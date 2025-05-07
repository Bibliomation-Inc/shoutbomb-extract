# Development Checklist

- [x] Filter notice queries to only include patrons that are returned by the `notice_prefs.sql` query.
  - [x] This should be done in the SQL queries for each notice type.
  - [x] Ensure that the queries are efficient and do not impact performance.
- [x] Parameterize queries to filter by library, using values from the `librarynames` and `include_org_descendents` in the config file.
  - [x] Do we need the option to include org descendants? Depends on how we intend to roll this out.
- [x] Add a `--dry-run` option to the scripts to allow testing without sending emails or uploading files.
  - [x] Use this to replace the `--no-email` and `--no-sftp` options and simplify the user experience.
- [x] Implement email limiting strategy for hold notice extracts. They run up to hourly which can result in a lot of emails.
- [x] Format language code to Shoutbomb's specific format (e.g., `en-US` to `en`).
- [x] Remove chunking functionality from shoutbomb extracts. The data is small enough that chunking is unnecessary.
- [x] Don't include data for overdue notices in the `daily_notices` extract. We decided to remove this from the extract and stick with hold notices and preoverdue notices.
- [x] Simplify strategy for getting item titles.
- [x] Remove diff overlap feature from scripts and config. It was necessary for Library IQ, but not for Shoutbomb.