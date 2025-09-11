# Evergreen Renewal Eligibility (as used by Courtesy Notices)

This document explains, in practical terms, how renewal eligibility is determined by the courtesy notice SQL query in this repository:
- sql/courtesy_notice.sql

The SQL implements a series of gating checks. If any check fails, the item will not be eligible for renewal (RENEWAL_REMAINING is set to 0). If all checks pass, RENEWAL_REMAINING reflects the item’s remaining renewal count.

## Scope of Circulations Considered
- Open circulations only:
  - Not checked in, not finished (checkin_time IS NULL, xact_finish IS NULL).
- Due within the next 3 days (inclusive).
- Patron not deleted.
- Recipients limited to patrons who:
  - Have opac.default_sms_notify set, and
  - Have opac.hold_notify containing "sms".
  - Note: The SMS settings limit who receives courtesy notices; they do not affect renewal policy itself.

## Gating Checks (in the order applied)

1) Renewal Policy Check
- Function: action.item_user_renew_test(circ_lib, copy_id, usr_id)
- The query evaluates the policy test and reduces it to a boolean success per circulation.
- If the policy test is not successful, renewal is blocked.

2) Fines Over Threshold
- The query preloads the applicable threshold per org unit from permission.grp_penalty_threshold where penalty = 1 (PATRON_EXCEEDS_FINES)
- It sums the patron’s positive balances from money.materialized_billable_xact_summary.
- It computes fines_over_threshold = max(balance_owed - threshold, 0).
- If fines_over_threshold > 0, renewal is blocked.

3) Standing Penalties (Blocking)
- Active standing penalties are read from actor.usr_standing_penalty for the patron:
  - Codes: 2 (PATRON_EXCEEDS_OVERDUE_COUNT), 3 (PATRON_EXCEEDS_CHECKOUT_COUNT), 5 (PATRON_EXCEEDS_LOST_COUNT), and 35 (PATRON_EXCEEDS_LONG_OVERDUE_COUNT) in courtesy_notice.sql 
  - “Active” means stop_date is NULL or in the future.
- If any of these active penalties exist, renewal is blocked.
- courtesy_notice.sql uses the penalties internally to block but does not expose a flag.

1) Blocking Holds on This Copy
- The query restricts expensive hold lookups to rows that passed policy, fines, penalties, and also have renewal_remaining > 0.
- It gathers hold candidates in two index-friendly ways:
  - Holds where the current_copy is the target.
  - Holds via action.hold_copy_map target_copy.
- It de-duplicates candidates per copy and then permits only those holds that pass:
  - action.hold_retarget_permit_test(pickup_lib, request_lib, copy_id, usr, requestor)
- The number of distinct permitted holds per circulation is “HOLD_COUNT”.
- If HOLD_COUNT > 0, renewal is blocked.

1) Renewal Count Remaining
- If the item’s renewal_remaining <= 0, renewal is blocked.

If all checks above pass, the item is considered eligible and RENEWAL_REMAINING equals the item’s renewal_remaining value.

## Output Fields of Interest
- FINES_OWED
  - Represents fines_over_threshold, i.e., the amount above the applicable org-unit threshold (not the total account balance).
- HOLD_COUNT
  - Count of distinct permitted holds that would block renewal for this copy.
- RENEWAL_REMAINING
  - 0 if any gating check fails.
  - Otherwise equals the item’s renewal_remaining from action.circulation.

Placeholders
- TIMES_RENEWED and MAX_RENEWAL are present as placeholders and are not used; see RENEWAL_REMAINING.

## Decision Logic (Pseudocode)

```
if !policy_success:                         block
else if fines_over_threshold > 0:           block
else if blocking_hold_count > 0:            block
else if has_active_blocking_penalty:        block
else if renewal_remaining <= 0:             block
else:                                       eligible with renewal_remaining
```

Where:
- policy_success is from action.item_user_renew_test.
- fines_over_threshold is computed from balance vs. grp_penalty_threshold (penalty=1).
- has_active_blocking_penalty is true if any of penalty codes (2,3,5,35) are active (stop_date null or > now()).
- blocking_hold_count is the count of permitted holds returned by action.hold_retarget_permit_test.

## Performance Notes
- Holds evaluation is restricted to rows that could actually renew (policy ok, fines ok, no penalties, renewal_remaining > 0).
- Hold candidates are constructed via both current_copy and hold_copy_map and de-duplicated before permit testing.
- The permit test is called once per de-duplicated candidate; LIMIT 1 is used in the correlated subquery.

## Extending or Adjusting the Logic
- To include/exclude different standing penalties, modify the IN (...) list in the penalty_users CTE.
- To change which fines are considered, adjust the threshold source or the fines summary used.
