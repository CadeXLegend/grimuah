// `any` in type position, which is the same escape as `as any`: a list of it, a
// generic argument, a return annotation. the corpus is linted with every layer
// on, so nothing here is a banned construct

export function widen(values: any[]): Array<any> {
  return values;
}

export function narrow(value: unknown): any {
  return value;
}

// a member access and an object key are names rather than types
export const Named = { any: "any" };

export const Read = Named.any;
