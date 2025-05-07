SELECT
    ac.barcode AS "PATRON_BARCODE",
    acp.barcode AS "ITEM_BARCODE",
    rmat.title AS "TITLE",
    circ.due_date::date AS "DUEDATE",
    (SELECT COALESCE(SUM(mmbxs.balance_owed), 0.00)
     FROM money.materialized_billable_xact_summary mmbxs
     WHERE mmbxs.usr = au.id AND mmbxs.balance_owed > 0) AS "FINES_OWED",
    (SELECT COUNT(*)
     FROM action.hold_request ahr
     WHERE ahr.target = bre.id
     AND ahr.fulfillment_time IS NULL
     AND ahr.cancel_time IS NULL) AS "HOLD_COUNT",
    (SELECT COUNT(*) 
     FROM action.circulation child_circ 
     WHERE child_circ.parent_circ = circ.id)::integer AS "TIMES_RENEWED",
    circ.renewal_remaining::integer AS "MAX_RENEWAL"
FROM
    action.circulation circ
JOIN 
    actor.usr au ON circ.usr = au.id
JOIN 
    actor.card ac ON au.card = ac.id
JOIN 
    asset.copy acp ON circ.target_copy = acp.id
JOIN 
    asset.call_number acn ON acp.call_number = acn.id
JOIN 
    biblio.record_entry bre ON acn.record = bre.id
JOIN 
    reporter.materialized_simple_record rmat ON acn.record = rmat.id
WHERE
    circ.checkin_time IS NULL
    AND circ.xact_finish IS NULL
    AND circ.due_date::date BETWEEN CURRENT_DATE AND (CURRENT_DATE + INTERVAL '3 days')
    AND EXISTS (
        SELECT 1
        FROM actor.usr_setting default_sms
        WHERE default_sms.usr = au.id
        AND default_sms.name = 'opac.default_sms_notify'
        AND EXISTS (
            SELECT 1
            FROM actor.usr_setting hold_notify
            WHERE hold_notify.usr = au.id
            AND hold_notify.name = 'opac.hold_notify'
            AND hold_notify.value ILIKE '%sms%'
        )
        AND au.deleted = false
    )
    AND circ.circ_lib IN ($$ORG_UNIT_FILTER$$)
ORDER BY
    circ.due_date ASC;