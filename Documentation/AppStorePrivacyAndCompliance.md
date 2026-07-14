# Motionary release compliance checklist

This checklist documents console and operational steps that cannot be enforced by the source repository.

## App Store Connect privacy answers

Review these answers for every release. The final selection depends on Apple's current questionnaire wording.

- Declare **User Content** for suggestion titles, descriptions, and report details.
- Declare **User ID** for the persistent pseudonymous Firebase UID.
- Declare technical identifiers or diagnostics used by Firebase Authentication and App Check where Apple's questionnaire requires them.
- Mark suggestion data and the UID as linked to the same pseudonymous user unless Apple's current definitions clearly permit a different answer.
- State that the data is used for app functionality, fraud prevention, security, and moderation—not advertising or tracking.
- Use `https://moysoft.com/privacy` as the privacy-policy URL.
- Use `https://moysoft.com/en/community` as the support/community-safety URL where appropriate.

## Firebase / Google

- Publish the repository's current `firestore.rules` and `firestore.indexes.json`.
- Enforce App Check for Cloud Firestore only after production App Attest traffic is visible and working.
- Keep the debug App Check token limited to development and remove obsolete debug tokens.
- Confirm the Firestore location is `europe-west3`.
- Keep Firebase Data Processing and Security Terms and current subprocessor information in the compliance records.
- Restrict Firebase project owners/editors and enable multi-factor authentication on administrator Google accounts.
- Review Firebase Authentication users and Firestore administrators periodically.

## Netlify legal-notice form

- Enable Netlify Forms for the deployed site.
- Confirm that the form `motionary-illegal-content-notice` is detected after deployment.
- Under **Project configuration → Notifications**, add an email notification to `hello@moysoft.com`.
- Submit one test notice and verify receipt, acknowledgement, moderation workflow, and deletion.
- Restrict Netlify team access and enable multi-factor authentication.

## Moderation operations

- Review in-app reports and formal legal notices promptly.
- Record the decision, date, reason, and action taken.
- Where contact details are available and required, acknowledge the notice and provide a reasoned decision.
- Provide an appeal route through `hello@moysoft.com`.
- Normally delete or anonymize resolved reports after 12 months.
- Retain records for up to three years only when necessary for legal claims, repeated abuse, or a legal obligation.
- Immediately escalate credible threats, child-safety material, or other urgent illegal content to qualified legal counsel and, where required, competent authorities.

## Legal review

- Have German/EU counsel review the Privacy Policy, Terms, EULA, Community Standards, DSA classification, retention schedule, and imprint before public launch.
- Re-check the documents whenever Firebase, Netlify, analytics, authentication, data fields, moderation, or international transfers change.
