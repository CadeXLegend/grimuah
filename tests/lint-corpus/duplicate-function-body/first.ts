export function spreadOf(amount: number, rate: number): number {
  return Math.round(amount * rate) + Math.floor(amount / rate);
}
