// a type this implementation module exports and another directory consumes, which is
// the placement the rule asks about: the consumer has to import the module that also
// implements behaviour to read a shape, so the two cannot change independently
//
// the row lands on the `export` line, and the surface's declaration file the message
// names is `shared-type-placement.types.ts`, the file name minus its behaviour kind

export type AccountBalance = { readonly amount: number };
