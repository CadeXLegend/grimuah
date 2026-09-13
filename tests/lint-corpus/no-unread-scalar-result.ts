// a call whose declared result is a bare boolean, dropped as a bare statement, and
// the shapes around it. `void` states the dropped result on purpose, so the
// detector reads it as the same defect rather than a different one
//
// the callee is declared in this fixture, because the rule's index is the whole
// project and a row here depends on a declaration in it. the corpus is linted with
// every layer on, so nothing here is a banned construct: no `let`, no `switch`, no
// `null`, no `throw`, no `for`, no `==`, no `as` cast, no mutable array and no bare
// boolean argument
//
// an assignment, a `Promise<void>` result and a name two declarations disagree
// about are all out of scope, which is the detector's own narrowing

export function clearChase(chaseId: string): Promise<boolean> {
  const settled = chaseId.length > 0;
  return Promise.resolve(settled);
}

export function countChases(ownerId: string): Promise<number> {
  return Promise.resolve(ownerId.length);
}

export function settleChase(chaseId: string): Promise<void> {
  return Promise.resolve(undefined);
}

export async function sweepChases(ownerId: string, chaseId: string): Promise<void> {
  await clearChase(ownerId);
  void clearChase(chaseId);
  const gone = await clearChase(chaseId);
  await countChases(ownerId);
  await settleChase(chaseId);
  logger.info(gone);
}
