// half of a cycle: this module imports the one below, and that one imports this
// back, so the two are one strongly connected component of two files. the surface
// firewall cannot see it, because both sit at the same dagOrder
//
// the import is the first statement, so the row lands on line 8. the name it brings
// in is used, so nothing else in the corpus has an opinion about this file

import { fromB } from "./no-import-cycles-b.repo";

export function fromA(): string {
  return fromB();
}
