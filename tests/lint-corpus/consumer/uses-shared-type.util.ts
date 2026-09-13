// the other end of the placement rule's question: this module sits in a directory of
// its own, so importing the type crosses a directory boundary. the consumer exports a
// function rather than a type, so nothing here is judged by the rule that judges the
// declaration's own module

import { AccountBalance } from "../shared-type-placement.repo";

export function balanceOf(balance: AccountBalance): number {
  return balance.amount;
}
