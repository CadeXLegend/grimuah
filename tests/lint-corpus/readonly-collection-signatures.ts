// a mutable array in the three positions the rule reads: a parameter, a return
// type, and an object type's property in a type literal and in an interface. the
// shapes it must leave alone sit here too: `readonly T[]`, `ReadonlyArray<T>`, an
// array behind a union and a qualified `globalThis.Array`. a class field is out
// of scope on purpose, because a mutable field is state the class owns, and a
// type alias and a local binding belong to the rule that covers the alias form.
// the corpus is linted with every layer on, so nothing here is a banned construct
// and every property is required and readonly

export type Queue = {
  readonly queued: Track[];
  readonly finished: Array<Track>;
  readonly frozen: readonly Track[];
  readonly ref: ReadonlyArray<Track>;
  readonly either: Track[] | undefined;
  readonly qualified: globalThis.Array<Track>;
};

export interface Player {
  readonly history: Track[];
}

export function order(queue: Track[]): Array<Track> {
  return [...queue];
}

export type Handoff = (rows: Track[], done: ReadonlyArray<Track>) => Track[];

export const held: Track[] = [];

export class Holder {
  private readonly queue: Track[] = [];
}
