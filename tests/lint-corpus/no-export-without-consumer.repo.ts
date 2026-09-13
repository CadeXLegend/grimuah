// an exported binding no other module of the corpus names, which is the defect this
// rule asks about: the export keyword widens a symbol's audience to the whole project,
// so when nobody outside ever names it the promise is false, the declaration is really
// module private, and only the keyword is wrong
//
// the file name carries the rule's own scope, which is the suffixed-module convention
// rather than a directory: a module named `<name>.<kind>.ts` is the one the rule reads,
// and `tests/lint-corpus` is the whole run, so the names here have to be ones no
// sibling fixture spells
//
// the rows land on the declared names rather than on the export keyword, so the type's
// row sits on its name and the const's on its own

export type OrphanedOutcome = { readonly code: string };

export const orphanedKey = "orphaned";
