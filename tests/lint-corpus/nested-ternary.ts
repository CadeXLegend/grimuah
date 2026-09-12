// a conditional inside a conditional: a two-branch decision becomes a tree the
// reader has to evaluate branch by branch. the corpus is linted with every layer
// on, so nothing here is a banned construct

export function pick(flag: boolean, other: boolean): string {
  return flag ? (other ? "a" : "b") : "c";
}

// a conditional wrapped in parentheses still sits inside the one that follows it
export const Wrapped = (isFirst ? "a" : "b") ? "c" : "d";

// a conditional handed to a call is nested in nothing
export const Alone = choose(isLast ? "a" : "b");
