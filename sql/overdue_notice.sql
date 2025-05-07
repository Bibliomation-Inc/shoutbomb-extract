SELECT
    ac.barcode AS "PATRON_BARCODE",
    acp.barcode AS "ITEM_BARCODE",
    rmat.title AS "TITLE",
    circ.due_date::date AS "OVERDUE_DATE",
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
    AND circ.due_date < CURRENT_DATE
    AND circ.due_date > (CURRENT_DATE - INTERVAL '180 days')
    AND circ.stop_fines NOT IN ('LOST', 'CLAIMSRETURNED')
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
    AND circ.id IN (
        SELECT id FROM action.circulation 
        WHERE checkin_time IS NULL
        AND xact_finish IS NULL
    )
ORDER BY
    circ.due_date ASC;
