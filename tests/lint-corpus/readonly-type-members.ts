// a mutable property of a type literal, at the top level of the literal and
// nested inside it. the interface below is the detector's own narrowing rather
// than an oversight: it walks `TypeLiteral` nodes only, so a property of an
// interface is never reported, and the rule is implemented as written. the
// corpus is linted with every layer on, so nothing here is a banned construct
// and no member is optional

export type Options = {
  readonly kept: string;
  changed: number;
  readonly nested: {
    alsoChanged: boolean;
  };
};

export interface Draft {
  changed: string;
}
