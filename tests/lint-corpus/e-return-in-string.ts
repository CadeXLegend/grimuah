export const f = (): void => {
  try {
    JSON.parse("{}");
  } catch {
    void "return 1";
  }
};
