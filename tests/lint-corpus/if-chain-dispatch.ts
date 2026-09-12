// a run of three branches that all test one subject, which is a dispatch table
// written as a chain of guards. the corpus is linted with every layer on, so
// nothing here is a banned construct

export function labelFor(kind: string): string {
  if (kind === "slam") {
    return "Slam";
  }
  if (kind === "sweep") {
    return "Sweep";
  }
  if (kind === "swipe") {
    return "Swipe";
  }
  return "Unknown";
}

// two branches over one subject are a pair of guards, not a table
export function pairFor(kind: string): string {
  if (kind === "a") {
    return "A";
  }
  if (kind === "b") {
    return "B";
  }
  return "Unknown";
}
