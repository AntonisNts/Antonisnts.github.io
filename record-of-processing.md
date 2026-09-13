# Record of Processing Activities

**Processor's record under GDPR Article 30(2).**

**Last updated: 13 September 2026**

This is an internal compliance record, not a customer-facing document. It is
kept because Article 30(2) requires a processor to maintain a written record of
the processing it carries out on behalf of its controllers, and to make it
available to a supervisory authority on request. A school that asks for it can
be sent a copy; it contains no personal data.

---

## 1. The processor

| | |
|---|---|
| Name | Antonis Christodoulou |
| Country | Republic of Cyprus |
| Contact | paystampapp@gmail.com |
| Representative in the EU | Not applicable — the processor is established in the EU |
| Data Protection Officer | None appointed. Article 37 does not require one: processing is not carried out by a public authority, and it involves neither large-scale regular monitoring nor large-scale special-category data |

## 2. The controllers

Each business using PayStamp is a separate controller. Controllers are the
account holders recorded in the `businesses` table, identified by the name and
contact email held there. The list is not duplicated here — the table is the
record, and a copy can be produced from it at any time.

Each controller is bound by the same written contract: the
[Data Processing Agreement](data-processing-agreement.md), which forms part of
the [Terms of Service](terms-of-service.md) accepted when the account is created.

## 3. Categories of processing carried out for each controller

The same categories apply to every controller; PayStamp does not process
different data for different schools.

- **Storing enrolment records** — student name, the programme or level enrolled
  in, enrolment start month, months marked paused.
- **Storing payment records** — which months a cash payment was confirmed for,
  the amount, and the history of changes to that record.
- **Sending payment receipts and reminders** on the controller's instruction,
  using a contact identifier the controller entered (typically a phone number
  for WhatsApp, Viber or SMS, or an email address).
- **Providing portal access** — authenticating the business owner, and
  authenticating parents who choose to link to a student card so they can see
  their own children's records.
- **Publishing announcements** the controller writes to the families linked to
  its students.
- **Exporting data** to spreadsheet or JSON at the request of the controller, or
  of a parent exercising portability over their own family's records.

No special-category data (Article 9) and no payment card or bank data are
processed. No profiling and no automated decision-making take place.

## 4. Categories of data subjects

- Students of the business.
- Parents or guardians, where the business records them or where the parent
  creates a family-portal login.
- The business owner and any staff they authorise.

## 5. Transfers to third countries

**None.** All personal data is stored and processed within the European Union.
No transfer outside the EU/EEA takes place, so no Chapter V safeguard is
currently required. If that changes, the DPA requires an appropriate safeguard
and notice to the controller first.

## 6. Sub-processors

| Sub-processor | Role | Location |
|---|---|---|
| Supabase | Database hosting, authentication | European Union — Frankfurt, Germany |

No other sub-processor is engaged. Hosting of the static application files
(GitHub Pages, Netlify) involves no personal data: the application is delivered
to the browser, and all personal data is read from and written to Supabase
directly.

## 7. General description of security measures (Article 32(1))

- **Encryption in transit.** All connections use HTTPS/TLS. No PayStamp page is
  served over plain HTTP.
- **Isolation between controllers.** Row-level security in the database is the
  boundary, not application code: a session carries the identity of one business
  or one parent, and the policies attached to every table restrict reads and
  writes to rows belonging to that identity. A query for another school's data
  returns nothing.
- **Least privilege on the database.** The browser holds only the publishable
  key. The `service_role` key is never shipped to a client. Execute permission on
  database functions is revoked from `public` and `anon` by default, and granted
  back one function at a time.
- **Restricted administrative access.** Direct database access is limited to the
  processor alone, through a single administrator account. No other person holds
  credentials to the database.
- **Column-level write control.** Where a field must not be self-assigned — the
  subscription plan is the example — the table's update permission is issued over
  named columns only, so it cannot be changed from the browser.
- **Rate limiting on public entry points.** Self-registration is throttled per
  registration link and per source address, so a public link cannot be used to
  flood a school with requests.
- **Change control.** Database migrations are run against a local replica of the
  full schema and must pass the automated test suite in `supabase/test/` before
  they are applied to the live project. Application changes are deployed to a
  staging site and verified there before reaching production.
- **Regular review.** Access rules and security configuration are reviewed
  periodically and after any change that touches authentication or row-level
  security.

### Known limitation

Automated database backups are not currently enabled — the hosting plan in use
does not include them. A manual export is the stopgap. This is recorded here
rather than omitted, because Article 32(1)(c) concerns the ability to restore
availability, and a school is entitled to know the position. See `DECISIONS.md`
for the circumstances under which this changes.

## 8. Breach procedure

On becoming aware of a personal data breach, the processor notifies the affected
controller or controllers without undue delay, with the information reasonably
available to help them meet their own 72-hour obligation under Article 33. The
processor is not itself the notifying party to the supervisory authority — the
controller is.
