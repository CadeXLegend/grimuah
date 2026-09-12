export const f = (): number => {
  try {
    return JSON.parse("1");
  } catch {
    return 0;
  }
};
