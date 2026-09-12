export const f = (): void => {
  for (
    (globalThis as unknown as { i: number }).i = 0;
    (globalThis as unknown as { i: number }).i < 2;
    (globalThis as unknown as { i: number }).i++
  ) {
    break;
  }
};
