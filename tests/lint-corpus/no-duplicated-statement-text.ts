// the same debit written against two handles, one named for accounts and one named
// for consumables. the sharing is what hides the repeat from every other duplication
// check, because the statement text is the only part the two call sites have in
// common. the corpus is linted with every layer on, so nothing here is a banned
// construct

export async function debitAccount(
  database: Database,
  userId: string,
  amount: number,
): Promise<void> {
  await database
    .prepare("UPDATE accounts SET balance = balance - ? WHERE user_id = ? AND balance >= ?")
    .run(userId, amount, amount);
}

export async function debitConsumable(
  database: Database,
  userId: string,
  amount: number,
): Promise<void> {
  const statement =
    "UPDATE accounts\n  SET balance = balance - ?\n  WHERE user_id = ? AND balance >= ?";
  await database.prepare(statement).run(userId, amount, amount);
}
