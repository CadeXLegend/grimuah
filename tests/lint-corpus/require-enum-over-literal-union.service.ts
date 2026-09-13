// a union of two or more string literals in each position the rule reads: a type
// alias, an interface property, a type-literal property, a variable and a
// parameter. the alias is broken across lines with a leading bar, which is the
// same union to the checker. the return annotation is a union too and is
// deliberately left alone, because the detector reads the four positions above
// and no function's return. the corpus is linted with every layer on, so nothing
// here is a banned construct and every property is required and readonly
//
// the file name carries the suffix the rule's own scope demands: a module named
// `<name>.<kind>.ts` is the only one an enum can replace a literal union in

export type Wave =
  | "left"
  | "right";

export interface Bearing {
  readonly side: "port" | "starboard";
}

export type Heading = { readonly turn: "near" | "far" };

export const limit: "low" | "high" = "low";

export function steer(direction: "up" | "down"): "forward" | "back" {
  return "forward";
}
