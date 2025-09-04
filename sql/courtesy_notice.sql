WITH sms_users AS (
  SELECT us.usr AS usr_id
  FROM actor.usr_setting us
  WHERE us.name = 'opac.default_sms_notify'
    AND EXISTS (
      SELECT 1
      FROM actor.usr_setting us2
      WHERE us2.usr = us.usr
        AND us2.name = 'opac.hold_notify'
        AND us2.value ILIKE '%sms%'
    )
),
base AS (
  SELECT
      circ.id                AS circ_id,
      circ.usr               AS usr_id,
      circ.circ_lib          AS circ_lib,
      circ.target_copy       AS copy_id,
      circ.due_date::date    AS duedate,
      circ.renewal_remaining,
      circ.auto_renewal_remaining,
      ac.barcode             AS patron_barcode,
      acp.barcode            AS item_barcode,
      acn.record             AS record_id
  FROM action.circulation circ
  JOIN actor.usr au          ON circ.usr = au.id
  JOIN sms_users su          ON su.usr_id = au.id
  JOIN actor.card ac         ON au.card = ac.id
  JOIN asset.copy acp        ON circ.target_copy = acp.id
  JOIN asset.call_number acn ON acp.call_number = acn.id
  WHERE
      circ.checkin_time IS NULL
      AND circ.xact_finish IS NULL
      AND circ.due_date::date BETWEEN CURRENT_DATE AND (CURRENT_DATE + INTERVAL '3 days')
      AND au.deleted = false
),
policy AS (
  SELECT b.circ_id,
         COALESCE(bool_and(t.success), false) AS success
  FROM base b
  LEFT JOIN LATERAL (
    SELECT success
    FROM action.item_user_renew_test(b.circ_lib, b.copy_id, b.usr_id)
  ) t ON TRUE
  GROUP BY b.circ_id
),
-- preload thresholds (penalty id = 1) once; some orgs will not have a row
fine_threshold_by_lib AS (
  SELECT gpt.org_unit AS circ_lib, MAX(gpt.threshold)::numeric AS threshold
  FROM permission.grp_penalty_threshold gpt
  WHERE gpt.penalty = 1
  GROUP BY gpt.org_unit
),
-- sum positive balances only for users in scope
base_users AS (SELECT DISTINCT usr_id FROM base),
fines_by_user AS (
  SELECT bu.usr_id,
         COALESCE(SUM(m.balance_owed), 0)::numeric AS fines_owed
  FROM base_users bu
  JOIN money.materialized_billable_xact_summary m
    ON m.usr = bu.usr_id
   AND m.balance_owed > 0
  GROUP BY bu.usr_id
),
fines_over_threshold AS (
  SELECT
    b.circ_id,
    CASE
      WHEN ftl.threshold IS NULL THEN 0::numeric
      ELSE GREATEST(COALESCE(fu.fines_owed, 0) - ftl.threshold, 0)::numeric
    END AS fines_over_threshold
  FROM base b
  LEFT JOIN fines_by_user fu        ON fu.usr_id   = b.usr_id
  LEFT JOIN fine_threshold_by_lib ftl ON ftl.circ_lib = b.circ_lib
),
-- New: users with active standing penalties that block renewal
-- Penalties included: 
-- 5 (PATRON_EXCEEDS_LOST_COUNT), 2 (PATRON_EXCEEDS_OVERDUE_COUNT), 3 (PATRON_EXCEEDS_CHECKOUT_COUNT)
-- 35 (PATRON_EXCEEDS_LONG_OVERDUE_COUNT)
penalty_users AS (
  SELECT DISTINCT usp.usr AS usr_id
  FROM base_users bu
  JOIN actor.usr_standing_penalty usp
    ON usp.usr = bu.usr_id
   AND usp.standing_penalty IN (5, 2, 3, 35)
   AND (usp.stop_date IS NULL OR usp.stop_date > now())
),
-- restrict the expensive holds work to rows which could actually renew
holds_scope AS (
  SELECT b.circ_id, b.copy_id
  FROM base b
  JOIN policy p ON p.circ_id = b.circ_id
  LEFT JOIN fines_over_threshold fot ON fot.circ_id = b.circ_id
  LEFT JOIN penalty_users pu ON pu.usr_id = b.usr_id
  WHERE COALESCE(p.success, false) = true
    AND b.renewal_remaining > 0
    AND COALESCE(fot.fines_over_threshold, 0) = 0
    AND pu.usr_id IS NULL
),
-- collect distinct copies only from the reduced scope
base_copies AS (
  SELECT DISTINCT copy_id FROM holds_scope
),
-- candidates via current_copy path (index-friendly)
current_copy_candidates AS (
  SELECT
    ahr.id,
    ahr.pickup_lib, ahr.request_lib, ahr.usr, ahr.requestor,
    ahr.current_copy AS copy_id
  FROM action.hold_request ahr
  JOIN base_copies bc ON ahr.current_copy = bc.copy_id
  WHERE ahr.cancel_time IS NULL
    AND ahr.fulfillment_time IS NULL
    AND COALESCE(ahr.frozen, false) = false
    AND (ahr.thaw_date IS NULL OR ahr.thaw_date <= now())
    AND (ahr.expire_time IS NULL OR ahr.expire_time > now())
),
-- candidates via hold_copy_map path (index-friendly)
map_candidates AS (
  SELECT
    ahr.id,
    ahr.pickup_lib, ahr.request_lib, ahr.usr, ahr.requestor,
    m.target_copy AS copy_id
  FROM action.hold_request ahr
  JOIN action.hold_copy_map m ON m.hold = ahr.id
  JOIN base_copies bc ON m.target_copy = bc.copy_id
  WHERE ahr.cancel_time IS NULL
    AND ahr.fulfillment_time IS NULL
    AND COALESCE(ahr.frozen, false) = false
    AND (ahr.thaw_date IS NULL OR ahr.thaw_date <= now())
    AND (ahr.expire_time IS NULL OR ahr.expire_time > now())
),
-- de-duplicate once before the permit test
candidate_holds AS (
  SELECT DISTINCT id, pickup_lib, request_lib, usr, requestor, copy_id
  FROM (
    SELECT * FROM current_copy_candidates
    UNION ALL
    SELECT * FROM map_candidates
  ) u
),
-- run hold_retarget_permit_test only for de-duped candidates
permitted AS (
  SELECT
    ch.copy_id,
    ch.id AS hold_id
  FROM candidate_holds ch
  WHERE (
    SELECT success
    FROM action.hold_retarget_permit_test(
           ch.pickup_lib, ch.request_lib, ch.copy_id, ch.usr, ch.requestor
    )
    LIMIT 1
  ) IS TRUE
),
-- aggregate permitted holds per circ
blocking_holds AS (
  SELECT b.circ_id,
         COUNT(DISTINCT p.hold_id)::int AS blocking_hold_count
  FROM base b
  LEFT JOIN permitted p ON p.copy_id = b.copy_id
  GROUP BY b.circ_id
)
SELECT
  b.patron_barcode AS "PATRON_BARCODE",
  b.item_barcode   AS "ITEM_BARCODE",
  rmat.title       AS "TITLE",
  b.duedate        AS "DUEDATE",
  COALESCE(fot.fines_over_threshold, 0)::numeric AS "FINES_OWED",
  COALESCE(bh.blocking_hold_count, 0)::int       AS "HOLD_COUNT",
  'Field not in use. See RENEWAL_REMAINING.'     AS "TIMES_RENEWED",
  'Field not in use. See RENEWAL_REMAINING.'     AS "MAX_RENEWAL",
  CASE
    WHEN NOT COALESCE(p.success, false) THEN 0
    WHEN COALESCE(fot.fines_over_threshold, 0) > 0 THEN 0
    WHEN COALESCE(bh.blocking_hold_count, 0) > 0 THEN 0
    WHEN pu2.usr_id IS NOT NULL THEN 0
    WHEN b.renewal_remaining <= 0 THEN 0
    ELSE b.renewal_remaining
  END::int AS "RENEWAL_REMAINING"
FROM base b
LEFT JOIN policy p   ON p.circ_id  = b.circ_id
LEFT JOIN blocking_holds bh ON bh.circ_id = b.circ_id
LEFT JOIN fines_over_threshold fot ON fot.circ_id = b.circ_id
LEFT JOIN penalty_users pu2 ON pu2.usr_id = b.usr_id
LEFT JOIN reporter.materialized_simple_record rmat ON rmat.id = b.record_id
ORDER BY b.duedate ASC;
