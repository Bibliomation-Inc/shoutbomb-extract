# Evergreen/Shoutbomb Integration Extras

This directory contains Evergreen action trigger templates for sending selected SMS-related messages to Shoutbomb through Shoutbomb's email gateway.

## Template Status

| Template | File | Bibliomation status |
| -------- | ---- | ------------------- |
| Hold Ready Notice | `hold_ready_at_template.tt2` | In production use |
| Test SMS | `test_sms_at_template.tt2` | Available for action trigger setup |
| Send Call Number | `send_call_number_at_template.tt2` | Available for action trigger setup |
| Courtesy Notice | `courtesy_at_template.tt2` | Not currently in use; WIP/informational |

The Hold Ready Notice template is currently used in production at Bibliomation. It is intended to replace the hold notice extract strategy for patron hold-ready SMS notifications. Bibliomation currently still runs the hold notice extracts twice daily for verification.

This action trigger approach restores staff visibility into patron notification history because Evergreen records the action trigger event. Staff can confirm when patrons were notified from the hold shelf or from the patron's triggered events log.

The Courtesy Notice template is not currently in use at Bibliomation. Treat its documentation and configuration details as provisional.

## Action Trigger Installation

Use these steps when configuring an Evergreen action trigger to send messages to Shoutbomb by email.

### Step 1: Copy or Create the Action Trigger

1. Navigate to **Admin -> Local Administration -> Notifications/Action Triggers**.
2. Clone an existing Evergreen trigger for the same workflow when one is available, such as SMS test, call number, or hold ready notification.
3. Give the cloned trigger a clear name, such as `Shoutbomb Test SMS`, `Shoutbomb Call Number SMS`, or `Shoutbomb Hold Ready SMS`.

### Step 2: Configure the Definition

1. Edit the new trigger.
2. Open the **Edit Definition** tab.
3. Copy the appropriate template file content into the template field:
   - Test SMS: `test_sms_at_template.tt2`
   - Send Call Number: `send_call_number_at_template.tt2`
   - Hold Ready Notice: `hold_ready_at_template.tt2`
   - Courtesy Notice: `courtesy_at_template.tt2` (not currently in use at Bibliomation)
4. In the **Reactor** section, set the reactor to `SendEmail`.
5. Save the definition.

### Step 3: Configure Shared Parameters

Open the **Edit Parameters** tab and add or update these parameters. These are shared by all templates in this directory:

- `sender_email`: Email address that sends notifications to Shoutbomb.
- `recipient_email`: Shoutbomb gateway email address provided by Shoutbomb.
- `bcc_email` (optional): Email address to blind copy for debugging or monitoring.

Example parameters:

```text
sender_email: your-email@example.com
recipient_email: 1234567890@shoutbomb.com
bcc_email: optional-bcc@example.com
```

For the Hold Ready Notice template, `check_sms_notify` is also required:

```text
check_sms_notify: 1
```

This is required when using the `HoldIsAvailable` validator so Evergreen checks SMS notification settings on the hold.

## Hold Ready Notice Action Trigger Template

File: `hold_ready_at_template.tt2`

The Hold Ready Notice template sends hold-ready data to Shoutbomb using a `HOLDRDY+` subject line. The template batches one or more available holds for the same patron and includes the title, hold shelf date, copy barcode, patron barcode, pickup library shortname, and shelf expiration date.

Because this template runs through Evergreen action triggers, the notification is visible in Evergreen's triggered events history. This is the production path at Bibliomation for hold-ready SMS notifications and is intended to replace the extract-based hold notification workflow. Bibliomation currently keeps the hold notice extracts running twice daily as a verification check.

### Hold Ready Requirements

The Hold Ready Notice action trigger requires these entries on the **Edit Environment** tab:

- `usr`: The user placing the hold.
- `usr.card`: The user's library card.
- `pickup_lib.billing_address`: The billing address of the pickup library.
- `current_copy.call_number.record.simple_record`: The simple record of the call number for the current copy.

It also expects this runtime data from the trigger target:

- The trigger target must provide one or more hold records.
- The first hold must include the patron object at `holds.0.usr`.
- The first hold must include the patron SMS number at `holds.0.sms_notify`.
- Each hold should include `current_copy`, `shelf_time`, `shelf_expire_time`, and `pickup_lib` values used by the template output.

Note: `check_sms_notify` checks notification settings on the hold object, which may differ from the patron's overall notification preferences.

## Test SMS Action Trigger Template

File: `test_sms_at_template.tt2`

The Test SMS template sends a confirmation message to verify that a patron's mobile number is registered correctly. It uses the patron's `opac.default_sms_notify` setting for the SMS destination.

## Send Call Number Action Trigger Template

File: `send_call_number_at_template.tt2`

The Send Call Number template sends item call number details, location, library, title, and author information through Shoutbomb.

## Courtesy Notice Action Trigger Template

File: `courtesy_at_template.tt2`

The Courtesy Notice template is intended for pre-overdue notices, but it is not currently in use at Bibliomation. Use the template and notes as a starting point only, and verify the workflow before relying on it in production.
