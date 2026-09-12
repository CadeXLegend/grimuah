export const f = (o: Record<string, number>): number => {
  let total = 0;
  for (const k in o) {
    total += o[k] ?? 0;
  }
  return total;
};
