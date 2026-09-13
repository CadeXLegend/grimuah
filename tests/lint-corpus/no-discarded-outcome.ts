// a call whose callee returns an Outcome, dropped as a bare statement, and the
// shapes around it. the callee is declared in this fixture, because the rule's
// index is the whole project and a row here depends on a declaration in it
//
// the corpus is linted with every layer on, so nothing here is a banned construct:
// no `let`, no `switch`, no `null`, no `throw`, no `for`, no `==`, no `as` cast, no
// mutable array and no bare boolean argument
//
// an assignment, a callee that declares no Outcome, and a name two declarations
// disagree about are all out of scope, which is the detector's own narrowing

export function creditDreams(userId: string): OperationOutcome<number> {
  return { succeeded: true, result: 1 };
}

export function readFlag(userId: string): boolean {
  return userId.length > 0;
}

export async function applyCredits(userId: string): Promise<void> {
  await creditDreams(userId);
  await readFlag(userId);
  const kept = await creditDreams(userId);
  logger.info(kept);
}
