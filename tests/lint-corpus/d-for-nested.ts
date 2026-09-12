export const f = (xs: number[]): number => {
  let total = 0;
  for (let i = 0; i < 3; i++) {
    for (const x of xs) {
      total += x + i;
    }
  }
  return total;
};
