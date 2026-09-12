// a for..of that builds an array by pushing into it, which is map written the
// long way. the corpus is linted with every layer on, so nothing here is a
// banned construct

export function collectNames(records: readonly NamedRecord[]): string[] {
  const names: string[] = [];
  for (const record of records) {
    names.push(record.name);
  }
  return names;
}

// the push belongs to the arrow, not to the loop that declares it
export function collectDeferred(records: readonly NamedRecord[]): string[] {
  const names: string[] = [];
  for (const record of records) {
    const take = (): void => {
      names.push(record.name);
    };
    handTo(take);
  }
  return names;
}

export function collectMapped(records: readonly NamedRecord[]): string[] {
  return records.map((record) => record.name);
}
