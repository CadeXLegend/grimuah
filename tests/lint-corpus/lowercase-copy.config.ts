// user-facing copy that starts lowercase. the file's own name is part of the
// test: the rule only reads `.config.ts` files, and the corpus is linted with
// every layer on, so nothing else here is a banned construct

export enum LowercaseMessage {
  StraySpirit = "stray spirit",
  Queued = "queued",
  Titled = "Stray spirit drifts in.",
  SingleWord = "singlewordhere",
}

export const HiddenLabel = `and ${hiddenCount} more queued`;

export const WholeLabel = `and three more queued`;
