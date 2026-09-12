// a function exported from a `.config.ts` file, which stops the file being a
// declaration. the file's own name is part of the test: the rule reads only
// `.config.ts` names, and the corpus is linted with every layer on, so nothing
// here is a banned construct

export enum Message {
  Ready = "Ready",
}

export const Key = "key";

export function buildKey(): string {
  return Key;
}

export const currentDateKey = (): string => Key;

const localHelper = (): string => Key;

export const LocalKey = localHelper();
