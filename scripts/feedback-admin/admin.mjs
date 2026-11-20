import { createHash } from "node:crypto";
import { pathToFileURL } from "node:url";
import { initializeApp } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import { FieldPath, FieldValue, getFirestore, Timestamp } from "firebase-admin/firestore";

async function* pages(query) {
  let page = await query.limit(50).get();
  while (!page.empty) {
    yield* page.docs;
    page = await query.startAfter(page.docs.at(-1)).get();
  }
}

async function deleteMatching(query) {
  while (true) {
    const page = await query.limit(50).get();
    if (page.empty) return;
    const batch = query.firestore.batch();
    for (const item of page.docs) batch.delete(item.ref);
    await batch.commit();
  }
}

async function removeVote(db, post, uid) {
  const vote = post.collection("votes").doc(uid);
  await db.runTransaction(async tx => {
    const [postSnapshot, voteSnapshot] = await tx.getAll(post, vote);
    const legacy = (postSnapshot.get("votedUsers") ?? []).includes(uid);
    if (voteSnapshot.exists) tx.delete(vote);
    if (!postSnapshot.exists || (!voteSnapshot.exists && !legacy)) return;
    const votes = Math.max(0, (postSnapshot.get("votes") ?? 0) - 1);
    tx.update(post, {
      votes, updatedAt: FieldValue.serverTimestamp(),
      ...(legacy ? { votedUsers: FieldValue.arrayRemove(uid) } : {}),
    });
  });
}

export async function processDeletion(db, auth, uid) {
  const marker = db.collection("suggestionAccountDeletions").doc(uid);
  const [request, admin] = await db.getAll(marker, db.collection("admins").doc(uid));
  const receipt = request.get("receipt");
  if (admin.exists || !request.exists || typeof receipt !== "string" || !/^[A-F0-9-]{36}$/.test(receipt)) {
    throw new Error("A valid guest deletion request is required.");
  }
  if (request.get("completedAt")) return;
  try {
    const user = await auth.getUser(uid);
    if (user.providerData.length || user.email || user.phoneNumber) throw new Error("This account is managed separately.");
  } catch (error) {
    if (error.code !== "auth/user-not-found") throw error;
  }

  const suggestions = db.collection("suggestions");
  for await (const post of pages(suggestions.where("ownerID", "==", uid).orderBy(FieldPath.documentId()))) {
    await deleteMatching(db.collection("suggestionKeys").where("suggestionID", "==", post.id));
    await deleteMatching(db.collection("suggestionReports").where("suggestionID", "==", post.id));
    await db.recursiveDelete(post.ref);
  }
  for await (const vote of pages(db.collectionGroup("votes").where("userID", "==", uid).orderBy(FieldPath.documentId()))) {
    const parent = vote.ref.parent.parent;
    if (parent?.parent.path === "suggestions") await removeVote(db, parent, uid);
  }
  for await (const post of pages(suggestions.where("votedUsers", "array-contains", uid).orderBy(FieldPath.documentId()))) {
    await removeVote(db, post.ref, uid);
  }
  await deleteMatching(db.collection("suggestionKeys").where("ownerID", "==", uid));
  await deleteMatching(db.collection("suggestionReports").where("reporterID", "==", uid));
  for (const collection of ["suggestionCooldowns", "suggestionCooldownOverrides", "bannedSuggestionUsers"]) {
    await db.collection(collection).doc(uid).delete();
  }
  try {
    await auth.deleteUser(uid);
  } catch (error) {
    if (error.code !== "auth/user-not-found") throw error;
  }
  const batch = db.batch();
  batch.update(marker, { completedAt: FieldValue.serverTimestamp() });
  batch.set(db.collection("suggestionDeletionReceipts").doc(receipt), { completed: true });
  await batch.commit();
}

async function pruneMarkers(db) {
  // The former Auth user's last ID token expires within one hour.
  await deleteMatching(db.collection("suggestionAccountDeletions").where("completedAt", "<",
    Timestamp.fromMillis(Date.now() - 24 * 60 * 60 * 1000)));
}

async function main() {
  const [projectId, command, uid] = process.argv.slice(2);
  if (!projectId || !["list", "delete", "prune"].includes(command) || (command === "delete" && !uid)) {
    throw new Error("Usage: node scripts/feedback-admin/admin.mjs PROJECT_ID list | delete UID | prune");
  }
  const app = initializeApp({ projectId });
  const db = getFirestore(app);
  if (command === "list") {
    for await (const request of pages(db.collection("suggestionAccountDeletions").orderBy(FieldPath.documentId()))) {
      if (!request.get("completedAt")) console.log(request.id, request.get("requestedAt").toDate().toISOString());
    }
  }
  if (command === "delete") await processDeletion(db, getAuth(app), uid);
  if (command === "prune") await pruneMarkers(db);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(error => {
    console.error(error.message);
    process.exitCode = 1;
  });
}
