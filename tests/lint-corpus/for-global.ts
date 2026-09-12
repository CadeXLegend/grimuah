export const f = (): void => {
  for (globalThis.i = 0; globalThis.i < 2; globalThis.i++) {
    break;
  }
};
