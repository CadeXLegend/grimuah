// two literals that retype values `literal-duplicating-config-value.config.ts` declares,
// and one that retypes nothing. the rule is a lookup of the consuming file's own surface,
// which is its path minus `.ts`, so the config beside it is the only one that can answer

const knownSubcommands = [
  "play",
  "skip",
  "join",
];

export function isKnown(subcommand: string): boolean {
  return knownSubcommands.includes(subcommand);
}
