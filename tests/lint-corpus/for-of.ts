export const f = (xs: number[]): number => {
  let total = 0;
  for (const x of xs) {
    total += x;
  }
  return total;
};
