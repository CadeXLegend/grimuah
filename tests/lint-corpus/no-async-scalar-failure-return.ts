// an exported async operation whose declared result is a bare boolean or
// number, in the three shapes the detector reaches: a function declaration, an
// arrow and a function expression. the corpus is linted with every layer on, so
// nothing here is a banned construct: no `let`, no `switch`, no `null`, no
// `throw`, no `for`, no `==`, no `as` cast, no mutable array and no bare boolean
// argument
//
// an unexported operation, a non-async one and a result that is not a bare
// scalar are all out of scope, which is the detector's own narrowing

export async function markSeen(userId: string): Promise<boolean> {
  return userId.length > 0;
}

export const retryCount = async (attempts: number): Promise<number> => attempts;

export const reload = async function (): Promise<boolean> {
  return true;
};

async function internal(): Promise<boolean> {
  return true;
}

// the reference keeps the hygiene layer quiet about the unexported operation
// above, which is the exclusion this fixture pins
export const used = internal;

export function plain(): Promise<boolean> {
  const answer = true;
  return Promise.resolve(answer);
}

export async function settled(): Promise<void> {}
