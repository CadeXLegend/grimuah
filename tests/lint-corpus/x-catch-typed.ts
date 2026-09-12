export const f = (): void => {
  try {
    JSON.parse("{}");
  } catch (e: unknown) {
    void e;
  }
};
