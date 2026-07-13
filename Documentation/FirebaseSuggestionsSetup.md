# Motionary Suggestions: free Firebase setup

Everything in the app and repository is prepared for Firebase's free Spark plan. No Cloud Functions or billing account is required.

## 1. Register App Check

1. Open [Firebase Console](https://console.firebase.google.com/).
2. Select the `motionary-9e87f` project.
3. Open **Build → App Check**.
4. Select the iOS app with bundle ID `com.moysoft.motionary`.
5. Choose **App Attest**.
6. Enter Apple Team ID `84TRSZD4QB` and save.
7. Do **not** enable enforcement yet.

## 2. Register the Xcode debug token

1. Open and run Motionary from Xcode once.
2. In Xcode's debug console, search for `Firebase App Check Debug Token`.
   If no token appears, add the `-FIRDebugEnabled` launch argument in **Product → Scheme → Edit Scheme → Run → Arguments**, then run again.
3. Copy the printed token.
4. Return to **Firebase Console → App Check → Apps**.
5. Open Motionary's overflow menu and choose **Manage debug tokens**.
6. Add the token with a name such as `Lian Mac Xcode`.
7. Run Motionary again and open **Settings → Suggestions**. Suggestions should load normally.

Debug builds use Firebase's debug provider. App Store and other Release builds use Apple App Attest.

## 3. Publish the Firestore rules

Do this only after step 2 works.

1. In Firebase Console, open **Build → Firestore Database → Rules**.
2. Replace the editor contents with the complete contents of `firestore.rules` from this repository.
3. Click **Publish**.
4. Run Motionary again and verify that creating, voting, editing, deleting, and reporting all work.

No custom Firestore index is required. Motionary checks the current user's vote documents directly, avoiding the collection-group index warning shown by earlier builds.

If your existing `suggestions` documents still contain `votedUsers` and do not contain `normalizationKey` or `status`, they are legacy documents. Leave them unchanged; Motionary reads them compatibly. A successfully created new suggestion will contain `normalizedTitle`, `normalizationKey`, `status`, `createdAt`, and a `votes/{uid}` subcollection.

These rules restrict edits and deletion to owners, make report documents private, validate document shapes, and limit vote documents to their authenticated UID. The 20-minute new-suggestion cooldown is enforced by the app. Fully trusted server-side throttling is not available without backend code.

## 4. Enable App Check enforcement

Leave the app running through normal testing first. In **Build → App Check → APIs**, inspect the request metrics.

When valid requests are appearing:

1. Enable enforcement for **Cloud Firestore**.
2. Enable enforcement for **Firebase Authentication** only after anonymous sign-in from both a debug build and a Release/TestFlight build has been confirmed.

Do not enable Cloud Functions enforcement; Motionary does not use Cloud Functions on the Spark plan.

## 5. Existing suggestions

Older suggestions remain readable and voteable. They do not have normalization keys, but the app checks their normalized titles locally before creating a new suggestion, so normal users are still redirected to the existing idea and automatically upvote it.

Suggestions created by the updated app use transaction-backed normalization keys, deterministic vote documents, and the cooldown automatically.

## Manual moderation

Reports appear at **Firestore Database → Data → suggestionReports**. Each document contains:

- `suggestionID`
- `reporterID`
- `reason`
- `createdAt`
- `status`

To hide a reported suggestion:

1. Open its document in the `suggestions` collection.
2. Change `status` from `approved` to `hidden`.

To restore it, change `status` back to `approved`. Automatic trusted moderation requires server code and is not available without enabling billing, so report decisions remain manual on Spark.
