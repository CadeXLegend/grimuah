// an exported enum in an implementation module is a configuration constant
// declared in the module that implements the behaviour, so it belongs in the
// surface's .config.ts file instead: the vocabulary gets a declaration home and
// the implementing module exports behaviour only
//
// the file name is the rule's own scope. a module named `<name>.<kind>.ts` two
// directories deep or more is an implementation module, which is why this
// fixture is `require-enum-in-config-file.repo.ts` under src/probe. a
// `.config.ts` is where the enum belongs rather than where it violates anything,
// a module with no behaviour kind is an entry point, and a module at the top of
// the tree is the shared root library
//
// only a top-level `export enum` counts. the unexported enum and the nested
// module block below are the two exclusions the detector decides on, and the
// finding lands on the `export` line because a declaration's modifiers are part
// of its own node

export enum AccountFailureReason {
  NotFound = "not-found",
  InsufficientFunds = "insufficient-funds",
}

enum LocalFailureReason {
  Gone = "gone",
}

declare module "remote" {
  export enum NestedReason {
    Gone = "gone",
  }
}
