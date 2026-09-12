// an await inside a loop body, which suspends once per element and turns a scan
// into n sequential round trips. the corpus is linted with every layer on, so
// nothing here is a banned construct

export async function loadEach(ids: string[]): Promise<void> {
  for (const id of ids) {
    await loadRecord(id);
  }
}

export async function loadTogether(ids: string[]): Promise<void> {
  const records = ids.map((id) => loadRecord(id));
  await Promise.all(records);
}

// the await belongs to the arrow, not to the loop that declares it
export async function loadDeferred(ids: string[]): Promise<void> {
  for (const id of ids) {
    const close = async (): Promise<void> => {
      await loadRecord(id);
    };
    handTo(close);
  }
}

export async function drain(queue: string[]): Promise<void> {
  while (queue.length > 0) {
    await pop(queue);
  }
}
