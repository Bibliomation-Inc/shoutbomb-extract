SELECT
    rmat.title AS "TITLE",
    ahr.shelf_time::date AS "HOLD AVAILABLE DATE",
    acp.barcode AS "ITEM BARCODE",
    ac.barcode AS "PATRON BARCODE",
    aou.shortname AS "PICKUP LOCATION",
    ahr.shelf_expire_time::date AS "HOLD PICKUP DATE"
FROM
    action.hold_request ahr
    JOIN asset.copy acp ON ahr.current_copy = acp.id
    JOIN asset.call_number acn ON acp.call_number = acn.id
    JOIN reporter.materialized_simple_record rmat ON acn.record = rmat.id
    JOIN actor.usr au ON ahr.usr = au.id
    JOIN actor.card ac ON au.card = ac.id
    JOIN actor.org_unit aou ON ahr.pickup_lib = aou.id
WHERE
    ahr.capture_time IS NOT NULL
    AND ahr.fulfillment_time IS NULL
    AND ahr.cancel_time IS NULL
    AND ahr.shelf_time IS NOT NULL
    AND ahr.shelf_time <= NOW()
    AND ahr.shelf_expire_time > NOW()
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
ORDER BY
    ahr.shelf_time;