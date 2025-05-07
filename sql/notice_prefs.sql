SELECT
    REGEXP_REPLACE(
        REGEXP_REPLACE(default_sms.value, '[^0-9]', '', 'g'),
        '^1?([0-9]{10})$', '\1'
    ) AS "PATRON_PHONE_NUMBER",
    ac.barcode AS "PATRON_BARCODE",
    SUBSTRING(au.locale FROM 1 FOR 2) AS "PATRON_LANGUAGE"
FROM
    actor.card ac
    JOIN actor.usr au ON au.card = ac.id
    JOIN actor.usr_setting default_sms ON default_sms.usr = au.id
    AND default_sms.name = 'opac.default_sms_notify'
WHERE
    au.deleted = false
    AND EXISTS (
        SELECT
            1
        FROM
            actor.usr_setting hold_notify
        WHERE
            hold_notify.usr = au.id
            AND hold_notify.name = 'opac.hold_notify'
            AND hold_notify.value ILIKE '%sms%'
    )
    AND au.home_ou IN ($$ORG_UNIT_FILTER$$)
ORDER BY
    ac.barcode;