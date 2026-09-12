// a prepare chain that ends in `all` with no LIMIT, so it transfers every
// matching row. the corpus is linted with every layer on, so nothing here is a
// banned construct

export async function loadCatches(database: Database): Promise<unknown[]> {
  return await database.prepare("SELECT fish_id, quantity FROM catches WHERE user_id = ?").all();
}

export async function loadOne(database: Database): Promise<unknown[]> {
  return await database.prepare("SELECT fish_id FROM catches WHERE user_id = ? LIMIT 1").all();
}

export async function loadFirst(database: Database): Promise<unknown> {
  return await database.prepare("SELECT fish_id FROM catches").first();
}
