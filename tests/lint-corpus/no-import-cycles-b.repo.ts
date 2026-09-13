// the other half of the cycle. the specifier reaches its neighbour without the
// extension, which is the form the resolver's first candidate accepts and the one
// the corpus's own modules use, and the import is again the first statement so both
// rows land on a line the cycle's own import occupies

import { fromA } from "./no-import-cycles-a.repo";

export function fromB(): string {
  return fromA();
}
