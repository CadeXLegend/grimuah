// a function past the complexity cap: sixteen branch statements and a final
// conditional are 18 paths, over the 15 the rule allows. the corpus is linted
// with every layer on, so nothing here is a banned construct

export function countBranches(seed: number, other: number): number {
  if (seed > 1) { seed = seed + 1; } else { seed = seed - 1; }
  if (seed > 1) { seed = seed + 1; } else { seed = seed - 1; }
  if (seed > 1) { seed = seed + 1; } else { seed = seed - 1; }
  if (seed > 1) { seed = seed + 1; } else { seed = seed - 1; }
  if (seed > 1) { seed = seed + 1; } else { seed = seed - 1; }
  if (seed > 1) { seed = seed + 1; } else { seed = seed - 1; }
  if (seed > 1) { seed = seed + 1; } else { seed = seed - 1; }
  if (seed > 1) { seed = seed + 1; } else { seed = seed - 1; }
  if (seed > 1) { seed = seed + 1; } else { seed = seed - 1; }
  if (seed > 1) { seed = seed + 1; } else { seed = seed - 1; }
  if (seed > 1) { seed = seed + 1; } else { seed = seed - 1; }
  if (seed > 1) { seed = seed + 1; } else { seed = seed - 1; }
  if (seed > 1) { seed = seed + 1; } else { seed = seed - 1; }
  if (seed > 1) { seed = seed + 1; } else { seed = seed - 1; }
  if (seed > 1) { seed = seed + 1; } else { seed = seed - 1; }
  if (seed > 1) { seed = seed + 1; } else { seed = seed - 1; }
  return seed > other ? seed : other;
}
